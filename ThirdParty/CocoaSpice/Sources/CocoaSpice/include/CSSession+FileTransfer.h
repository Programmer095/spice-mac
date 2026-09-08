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

#import "CSSession.h"

NS_ASSUME_NONNULL_BEGIN

/// Client → guest file transfer over the SPICE agent.
///
/// The agent's file transfer is one-way by design: there is no guest → client
/// counterpart in the protocol. Use WebDAV directory sharing (`CSSession+Sharing`)
/// for the other direction.
@interface CSSession (FileTransfer)

/// Whether the guest agent is present and has not disabled file transfer.
@property (nonatomic, readonly) BOOL canSendFiles;

/// Copy files into the guest. The guest agent chooses the destination — typically
/// the logged-in user's Desktop or downloads directory.
/// @param urls Local file URLs to send.
/// @param progress Called on the main queue with overall completion, 0.0–1.0.
/// @param completion Called on the main queue; `error` is nil on success.
- (void)sendFiles:(NSArray<NSURL *> *)urls
         progress:(nullable void (^)(double fraction))progress
       completion:(nullable void (^)(NSError *_Nullable error))completion;

/// Cancel every transfer still in flight for this session.
- (void)cancelFileTransfers;

@end

NS_ASSUME_NONNULL_END
