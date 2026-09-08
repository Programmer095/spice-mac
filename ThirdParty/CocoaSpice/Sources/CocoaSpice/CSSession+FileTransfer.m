//
// Copyright © 2026 spice-mac contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "CSSession+FileTransfer.h"
#import "CSSession+Protected.h"
#import "CSMain.h"
#import <objc/runtime.h>
#import <spice-client.h>
#import <spice/vd_agent.h>

NSString *const kCSFileTransferErrorDomain = @"org.spicemac.FileTransfer";

/// Owns everything one `sendFiles:` call needs to outlive the call itself: the
/// caller's blocks, the GFile refs, and the cancellable.
@class CSFileTransferHandle;

@interface CSSession (FileTransferPrivate)
- (NSMutableArray<CSFileTransferHandle *> *)cs_activeTransfers;
@end

@interface CSFileTransferHandle : NSObject
@property (nonatomic, weak, nullable) CSSession *owner;
@property (nonatomic, copy, nullable) void (^progress)(double);
@property (nonatomic, copy, nullable) void (^completion)(NSError *_Nullable);
@property (nonatomic, assign) GFile **sources;
@property (nonatomic, assign) NSUInteger sourceCount;
@property (nonatomic, assign) GCancellable *cancellable;
@end

@implementation CSFileTransferHandle

- (void)dispose {
    if (_sources) {
        for (NSUInteger i = 0; i < _sourceCount; i++) {
            if (_sources[i]) { g_object_unref(_sources[i]); }
        }
        g_free(_sources);
        _sources = NULL;
    }
    if (_cancellable) {
        g_object_unref(_cancellable);
        _cancellable = NULL;
    }
}

@end

static void cs_file_transfer_progress(goffset current, goffset total, gpointer user_data)
{
    CSFileTransferHandle *handle = (__bridge CSFileTransferHandle *)user_data;
    if (!handle.progress) { return; }
    double fraction = (total > 0) ? ((double)current / (double)total) : 0.0;
    void (^block)(double) = handle.progress;
    dispatch_async(dispatch_get_main_queue(), ^{ block(fraction); });
}

static void cs_file_transfer_finished(GObject *source, GAsyncResult *result, gpointer user_data)
{
    // Balances the __bridge_retained at the call site; the handle dies with this scope.
    CSFileTransferHandle *handle = (__bridge_transfer CSFileTransferHandle *)user_data;
    [[handle.owner cs_activeTransfers] removeObject:handle];
    GError *error = NULL;
    spice_main_channel_file_copy_finish(SPICE_MAIN_CHANNEL(source), result, &error);

    NSError *nsError = nil;
    if (error) {
        // G_IO_ERROR_CANCELLED is the user pressing Cancel, not a failure worth alerting on.
        if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
            NSString *message = error->message ? @(error->message) : @"The transfer failed.";
            nsError = [NSError errorWithDomain:kCSFileTransferErrorDomain
                                          code:error->code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        g_error_free(error);
    }

    void (^completion)(NSError *_Nullable) = handle.completion;
    [handle dispose];
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nsError); });
    }
}

@implementation CSSession (FileTransfer)

static const void *kActiveTransfersKey = &kActiveTransfersKey;

- (NSMutableArray<CSFileTransferHandle *> *)cs_activeTransfers {
    NSMutableArray *transfers = objc_getAssociatedObject(self, kActiveTransfersKey);
    if (!transfers) {
        transfers = [NSMutableArray array];
        objc_setAssociatedObject(self, kActiveTransfersKey, transfers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return transfers;
}

- (BOOL)canSendFiles {
    if (!self.main) { return NO; }
    return !spice_main_channel_agent_test_capability(self.main, VD_AGENT_CAP_FILE_XFER_DISABLED);
}

- (void)sendFiles:(NSArray<NSURL *> *)urls
         progress:(nullable void (^)(double))progress
       completion:(nullable void (^)(NSError *_Nullable))completion {
    if (urls.count == 0) {
        if (completion) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); }
        return;
    }
    if (!self.canSendFiles) {
        NSError *error = [NSError errorWithDomain:kCSFileTransferErrorDomain
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             @"The guest agent is not available, or file transfer is disabled in the guest. Install and start spice-vdagent."}];
        if (completion) { dispatch_async(dispatch_get_main_queue(), ^{ completion(error); }); }
        return;
    }

    CSFileTransferHandle *handle = [CSFileTransferHandle new];
    handle.progress = progress;
    handle.completion = completion;
    handle.cancellable = g_cancellable_new();

    // spice-gtk takes the array as NULL-terminated; hold our own refs until the
    // transfer finishes rather than assuming the callee retains them.
    handle.sourceCount = urls.count;
    handle.sources = g_new0(GFile *, urls.count + 1);
    for (NSUInteger i = 0; i < urls.count; i++) {
        handle.sources[i] = g_file_new_for_path([urls[i].path UTF8String]);
    }

    handle.owner = self;
    [[self cs_activeTransfers] addObject:handle];

    SpiceMainChannel *main = self.main;
    GFile **sources = handle.sources;
    GCancellable *cancellable = handle.cancellable;
    void *progressData = (__bridge void *)handle;
    void *completionData = (__bridge_retained void *)handle;

    [CSMain.sharedInstance asyncWith:^{
        spice_main_channel_file_copy_async(main,
                                           sources,
                                           G_FILE_COPY_NONE,
                                           cancellable,
                                           progress ? cs_file_transfer_progress : NULL,
                                           progressData,
                                           cs_file_transfer_finished,
                                           completionData);
    }];
}

- (void)cancelFileTransfers {
    for (CSFileTransferHandle *handle in [[self cs_activeTransfers] copy]) {
        if (handle.cancellable) { g_cancellable_cancel(handle.cancellable); }
    }
}

@end
