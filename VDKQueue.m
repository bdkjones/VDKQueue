//  VDKQueue.m
//  Created by Bryan D K Jones on 28 March 2012
//  Copyright 2013 Bryan D K Jones
//
//  Based heavily on UKKQueue, which was created and copyrighted by Uli Kusterer on 21 Dec 2003.
//
//  This software is provided 'as-is', without any express or implied
//  warranty. In no event will the authors be held liable for any damages
//  arising from the use of this software.
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//      1. The origin of this software must not be misrepresented; you must not
//      claim that you wrote the original software. If you use this software
//      in a product, an acknowledgment in the product documentation would be
//      appreciated but is not required.
//      2. Altered source versions must be plainly marked as such, and must not be
//      misrepresented as being the original software.
//      3. This notice may not be removed or altered from any source
//      distribution.

#import "VDKQueue.h"

NSString *const VDKQueueRenameNotification = @"VDKQueueFileRenamedNotification";
NSString *const VDKQueueWriteNotification = @"VDKQueueFileWrittenToNotification";
NSString *const VDKQueueDeleteNotification = @"VDKQueueFileDeletedNotification";
NSString *const VDKQueueAttributeChangeNotification = @"VDKQueueFileAttributesChangedNotification";
NSString *const VDKQueueSizeIncreaseNotification = @"VDKQueueFileSizeIncreasedNotification";
NSString *const VDKQueueLinkCountChangeNotification = @"VDKQueueLinkCountChangedNotification";
NSString *const VDKQueueAccessRevocationNotification = @"VDKQueueAccessWasRevokedNotification";

#pragma mark - VDKQueuePathEntry

// This is a simple model class used to hold info about each path we watch.

@interface VDKQueuePathEntry : NSObject

@property (atomic, copy) NSString *path;
@property (atomic) int watchedFD;
@property (atomic) VDKQueueEvent subscriptionFlags;

- (instancetype)initWithPath:(NSString *)inPath subscriptionFlags:(VDKQueueEvent)flags;

@end

@implementation VDKQueuePathEntry

- (instancetype)initWithPath:(NSString *)inPath subscriptionFlags:(VDKQueueEvent)flags
{
    self = [super init];
    if (self)
    {
        _path = [inPath copy];
        _watchedFD = open([_path fileSystemRepresentation], O_EVTONLY, 0);
        if (_watchedFD < 0)
            return nil;

        _subscriptionFlags = flags;
    }
    return self;
}

- (void)dealloc
{
    if (_watchedFD >= 0)
        close(_watchedFD);
}

@end

#pragma mark - VDKQueue

@interface VDKQueue () {
    /// The actual kqueue ID (Unix file descriptor).
    int _coreQueueFD;
    /// List of VDKQueuePathEntries. Keys are NSStrings of the path that each VDKQueuePathEntry is for.
    NSMutableDictionary *_watchedPathEntries;
    /// Set to NO to cancel the thread that watches _coreQueueFD for kQueue events
    BOOL _keepWatcherThreadRunning;
}

@end

@implementation VDKQueue

#pragma mark - INIT/DEALLOC

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _coreQueueFD = kqueue();
        if (_coreQueueFD == -1)
            return nil;

        _alwaysPostNotifications = NO;
#if TARGET_OS_IPHONE
        _sleepInterval = 60;
#else
        _sleepInterval = 0;
#endif
        _watchedPathEntries = [[NSMutableDictionary alloc] init];

		_queue = dispatch_get_main_queue();
    }
    return self;
}

- (void)dealloc
{
    // Shut down the thread that's scanning for kQueue events
    _keepWatcherThreadRunning = NO;

    // Do this to close all the open file descriptors for files we're watching
    [self removeAllPaths];
}

#pragma mark - PRIVATE METHODS

- (VDKQueuePathEntry *)addPathToQueue:(NSString *)path notifyingAbout:(VDKQueueEvent)flags
{
    @synchronized(self)
    {
        // Are we already watching this path?
        VDKQueuePathEntry *pathEntry = _watchedPathEntries[path];

        if (pathEntry)
        {
            // All flags already set?
            if (([pathEntry subscriptionFlags] & flags) == flags)
                return pathEntry;

            flags |= [pathEntry subscriptionFlags];
        }

        struct timespec     nullts = { 0, 0 };
        struct kevent       ev;

        if (!pathEntry)
            pathEntry = [[VDKQueuePathEntry alloc] initWithPath:path subscriptionFlags:flags];

        if (pathEntry)
        {
            EV_SET(&ev, [pathEntry watchedFD], EVFILT_VNODE, EV_ADD | EV_ENABLE | EV_CLEAR, flags, 0, (__bridge void *)pathEntry);

            [pathEntry setSubscriptionFlags:flags];

            _watchedPathEntries[path] = pathEntry;
            kevent(_coreQueueFD, &ev, 1, NULL, 0, &nullts);

            // Start the thread that fetches and processes our events if it's not already running.
            if (!_keepWatcherThreadRunning)
            {
                _keepWatcherThreadRunning = YES;
                [NSThread detachNewThreadSelector:@selector(watcherThread:) toTarget:self withObject:nil];
            }
        }

        return pathEntry;
    }

    return nil;
}

- (void)watcherThread:(id)sender
{
    int                 n;
    struct kevent       ev;
    struct timespec     timeout = { 1, 0 };     // 1 second timeout. Should be longer, but we need this thread to exit when a kqueue is dealloced, so 1 second timeout is quite a while to wait.
    int                 theFD = _coreQueueFD;   // So we don't have to risk accessing iVars when the thread is terminated.

    NSMutableArray      *notesToPost = [[NSMutableArray alloc] initWithCapacity:5];

#if DEBUG_LOG_THREAD_LIFETIME
    NSLog(@"watcherThread started.");
#endif

    [[NSThread currentThread] setName:@"VDKQueue Watcher Thread"];

    while (_keepWatcherThreadRunning)
    {
        @try
        {
            n = kevent(theFD, NULL, 0, &ev, 1, &timeout);
            if (n <= 0)
                continue;

            if (ev.filter != EVFILT_VNODE)
                continue;

            if (!ev.fflags)
                continue;

            //
            //  Note: VDKQueue gets tested by thousands of CodeKit users who each watch several thousand files at once.
            //      I was receiving about 3 EXC_BAD_ACCESS (SIGSEGV) crash reports a month that listed the 'path' objc_msgSend
            //      as the culprit. That suggests the KEVENT is being sent back to us with a udata value that is NOT what we assigned
            //      to the queue, though I don't know why and I don't know why it's intermittent. Regardless, I've added an extra
            //      check here to try to eliminate this (infrequent) problem. In theory, a KEVENT that does not have a VDKQueuePathEntry
            //      object attached as the udata parameter is not an event we registered for, so we should not be "missing" any events. In theory.
            //
            id pe = (__bridge id)ev.udata;
            if (!pe || ![pe respondsToSelector:@selector(path)])
                continue;

            NSString *fpath = ((VDKQueuePathEntry *)pe).path;
            if (!fpath)
                continue;

            @autoreleasepool {
                // Clear any old notifications
                [notesToPost removeAllObjects];

                // Figure out which notifications we need to issue
                if ((ev.fflags & NOTE_RENAME) == NOTE_RENAME)
                {
                    [notesToPost addObject:VDKQueueRenameNotification];
                }
                if ((ev.fflags & NOTE_WRITE) == NOTE_WRITE)
                {
                    [notesToPost addObject:VDKQueueWriteNotification];
                }
                if ((ev.fflags & NOTE_DELETE) == NOTE_DELETE)
                {
                    [notesToPost addObject:VDKQueueDeleteNotification];
                }
                if ((ev.fflags & NOTE_ATTRIB) == NOTE_ATTRIB)
                {
                    [notesToPost addObject:VDKQueueAttributeChangeNotification];
                }
                if ((ev.fflags & NOTE_EXTEND) == NOTE_EXTEND)
                {
                    [notesToPost addObject:VDKQueueSizeIncreaseNotification];
                }
                if ((ev.fflags & NOTE_LINK) == NOTE_LINK)
                {
                    [notesToPost addObject:VDKQueueLinkCountChangeNotification];
                }
                if ((ev.fflags & NOTE_REVOKE) == NOTE_REVOKE)
                {
                    [notesToPost addObject:VDKQueueAccessRevocationNotification];
                }

                NSArray *notes = [[NSArray alloc] initWithArray:notesToPost];   // notesToPost will be changed in the next loop iteration, which will likely occur before the block below runs.

                // Post the notifications (or call the delegate method) on the specified queue.
                dispatch_async(_queue, ^{
                    for (NSString *note in notes)
                    {
                        [_delegate queue:self didReceiveNotification:note forPath:fpath];

                        if (!_delegate || _alwaysPostNotifications)
                            [[NSNotificationCenter defaultCenter] postNotificationName:note object:self userInfo:@{@"path": fpath}];
                    }
                });
            }
        }
        @catch (NSException *localException)
        {
            NSLog(@"Error in VDKQueue watcherThread: %@", localException);
        }

#if TARGET_OS_IPHONE
        [NSThread sleepForTimeInterval:_sleepInterval];     // To save power on iOS
#endif
    }

    // Close our kqueue's file descriptor
    if (close(theFD) == -1) {
        NSLog(@"VDKQueue watcherThread: Couldn't close main kqueue (%d)", errno);
    }

#if DEBUG_LOG_THREAD_LIFETIME
    NSLog(@"watcherThread finished.");
#endif
}

#pragma mark - PUBLIC METHODS

- (void)addPath:(NSString *)aPath
{
    if (!aPath)
        return;

    @synchronized(self)
    {
        VDKQueuePathEntry *entry = _watchedPathEntries[aPath];

        // Only add this path if we don't already have it.
        if (!entry)
        {
            entry = [self addPathToQueue:aPath notifyingAbout:VDKQueueEventAll];
            if (!entry) {
                NSLog(@"VDKQueue tried to add the path %@ to watchedPathEntries, but the VDKQueuePathEntry was nil. \nIt's possible that the host process has hit its max open file descriptors limit.", aPath);
            }
        }
    }
}

- (void)addPath:(NSString *)aPath notifyingAbout:(VDKQueueEvent)flags
{
    if (!aPath)
        return;

    @synchronized(self)
    {
        VDKQueuePathEntry *entry = _watchedPathEntries[aPath];

        // Only add this path if we don't already have it.
        if (!entry)
        {
            entry = [self addPathToQueue:aPath notifyingAbout:flags];
            if (!entry) {
                NSLog(@"VDKQueue tried to add the path %@ to watchedPathEntries, but the VDKQueuePathEntry was nil. \nIt's possible that the host process has hit its max open file descriptors limit.", aPath);
            }
        }
    }
}

- (void)removePath:(NSString *)aPath
{
    if (!aPath)
        return;

    @synchronized(self)
    {
        VDKQueuePathEntry *entry = _watchedPathEntries[aPath];

        // Remove it only if we're watching it.
        if (entry) {
            [_watchedPathEntries removeObjectForKey:aPath];
        }
    }
}

- (void)removeAllPaths
{
    @synchronized(self)
    {
        [_watchedPathEntries removeAllObjects];
    }
}

- (NSUInteger)numberOfWatchedPaths
{
    NSUInteger count;

    @synchronized(self)
    {
        count = [_watchedPathEntries count];
    }

    return count;
}

@end
