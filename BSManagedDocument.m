//
//  BSManagedDocument.m
//
//  Created by Sasmito Adibowo on 29-08-12.
//  Rewritten by Mike Abdullah on 02-11-12.
//  Copyright (c) 2012-2013 Karelia Software, Basil Salad Software. All rights reserved.
//  http://basilsalad.com
//
//  Licensed under the BSD License <http://www.opensource.org/licenses/bsd-license>
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
//  EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
//  OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT_s
//  SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
//  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
//  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
//  BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
//  STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
//  THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "BSManagedDocument.h"

#import <objc/message.h>

NSString* BSManagedDocumentDidSaveNotification = @"BSManagedDocumentDidSaveNotification" ;
NSString* BSManagedDocumentErrorDomain = @"BSManagedDocumentErrorDomain" ;

@interface BSManagedDocument ()

@property(nonatomic, copy) NSURL *autosavedContentsTempDirectoryURL;
@property(atomic, assign) BOOL isSaving;
@property(atomic, assign) BOOL shouldCloseWhenDoneSaving;
@property (atomic, copy) BOOL (^writingBlock)(NSURL*, NSSaveOperationType, NSURL*, NSError**);
@property (nonatomic, readonly) NSPersistentContainer *persistentContainer;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;
@property (nonatomic, readonly) NSPersistentStore *store;
@property (nonatomic, readonly, getter=isCoordinatorConfigured) BOOL coordinatorConfigured;
@property (readonly, copy) NSURL *mostRecentlySavedFileURL;

@end


@implementation BSManagedDocument

- (void)setWritingBlock:(WritingBlockType)writingBlock {
    if (_writingBlock) {
#if !__has_feature(objc_arc)
        Block_release(_writingBlock);
#endif
    }
    
    if (writingBlock) {
#if !__has_feature(objc_arc)
        _writingBlock = Block_copy(writingBlock);
#else
        _writingBlock = [writingBlock copy];
#endif
    } else {
        _writingBlock = nil;
    }
}

- (WritingBlockType)writingBlock {
    return _writingBlock;
}

#pragma mark UIManagedDocument-inspired methods

+ (NSString *)storeContentName; { return @"StoreContent"; }
+ (NSString *)persistentStoreName; { return @"persistentStore"; }

+ (NSString *)storePathForDocumentPath:(NSString*)path
{
    BOOL isDirectory = YES;
    [NSFileManager.defaultManager fileExistsAtPath:path
                                       isDirectory:&isDirectory];
    /* I added the initialization YES on 20180114 after seeing a runtime
     warning here, sayig that isDirectory had a "Load of value -96,
     which is not a valid value for type 'BOOL' (aka 'signed char')". */
    if (isDirectory)
    {
        /* path is a file package. */
        path = [path stringByAppendingPathComponent:self.storeContentName];
        path = [path stringByAppendingPathComponent:self.persistentStoreName];
    }

    return path;
}

+ (NSURL *)persistentStoreURLForDocumentURL:(NSURL *)fileURL;
{
    NSString *storeContent = self.storeContentName;
    if (storeContent) fileURL = [fileURL URLByAppendingPathComponent:storeContent];
    
    fileURL = [fileURL URLByAppendingPathComponent:self.persistentStoreName];
    return fileURL;
}

- (BOOL)isCoordinatorConfigured {
    return _container.persistentStoreCoordinator.persistentStores.count > 0;
}

- (NSPersistentContainer *)persistentContainer {
    if (!_container) {
        _container = [[NSPersistentContainer alloc] initWithName:[[self class] persistentStoreName]
                                              managedObjectModel:[self managedObjectModel]];
    }
    return _container;
}

- (NSManagedObjectContext *)managedObjectContext;
{
    NSPersistentContainer *container = self.persistentContainer;
    
    if (!self.isCoordinatorConfigured) {
        // The viewContext returned by an unconfigured container can't be saved.
        // In previous implementations / forks, an unsaved document would be backed
        // by an unaffiliated managedObjectContext, which could be "saved" without
        // disk backing, and which could be associated with a persistent store later.
        // This kind of "late binding" isn't allowed under the NSPersistentContainer regime,
        // and so we need the persistent store to be configured before accessing the context.
        // The easiest way to do that without requiring changes to subclasses is to force
        // a synchronous autosave before returning the context for the first time.
        [self updateChangeCount:NSChangeDone];
        [super autosaveWithImplicitCancellability:YES
                               completionHandler:^(NSError *errorOrNil) {
                                   [self updateChangeCount:NSChangeCleared];
                               }];
        [self performSynchronousFileAccessUsingBlock:^{ }];
    }

    return container.viewContext;
}

// Allow subclasses to have custom undo managers. Return nil for no manager
+ (Class)undoManagerClass; {return [NSUndoManager class]; }

- (NSManagedObjectModel *)managedObjectModel;
{
    if (!_managedObjectModel)
    {
        _managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:@[NSBundle.mainBundle]];

#if ! __has_feature(objc_arc)
        [_managedObjectModel retain];
#endif
    }

    return _managedObjectModel;
}

- (BOOL)configurePersistentStoreCoordinatorWithDescription:(NSPersistentStoreDescription *)description
                                                     error:(NSError **)error_p {
    __block NSError *error = nil;
    NSPersistentContainer *container = self.persistentContainer;
    void (^setUndoManagerBlock)(NSManagedObjectContext *) = ^(NSManagedObjectContext *context){
        /* In macOS 10.11 and earler, the newly-initialized `context`
         typically found at this point will have a NSUndoManager.  But in
         macOS 10.12 and later, surprise, it will have nil undo manager.
         https://github.com/karelia/BSManagedDocument/issues/47
         https://github.com/karelia/BSManagedDocument/issues/50
         In either case, this may be not what the developer has specified
         in overriding +undoManagerClass.  So we test… */
        if (self.class.undoManagerClass)
        {
            /* This branch will always execute, *except* when +undoManagerClass is
             overridden to return nil. */
            NSUndoManager *undoManager = [[self.class.undoManagerClass alloc] init];
            context.undoManager = undoManager;
#if !__has_feature(objc_arc)
            [undoManager release];
#endif
        }
        self.undoManager = context.undoManager;
    };

    description.shouldAddStoreAsynchronously = NO;
    container.persistentStoreDescriptions = @[ description ];
    [container loadPersistentStoresWithCompletionHandler:
         ^(NSPersistentStoreDescription *addedDescription, NSError *addError) {
        error = addError;
#if ! __has_feature(objc_arc)
        [error retain];
#endif
        if (!error)
            [self performBlockAndWaitOnViewContext:setUndoManagerBlock];
    }];
    return (error == nil);
}

- (BOOL)configurePersistentStoreCoordinatorForURL:(NSURL *)storeURL
                                           ofType:(NSString *)fileType
                               modelConfiguration:(NSString *)configuration
                                     storeOptions:(NSDictionary<NSString *,id> *)storeOptions
                                            error:(NSError **)error_p
{
    NSPersistentStoreDescription *description = [NSPersistentStoreDescription persistentStoreDescriptionWithURL:storeURL];
    [storeOptions enumerateKeysAndObjectsUsingBlock:^(NSString *storeKey, id storeVal, BOOL *stop) {
        [description setOption:storeVal forKey:storeKey];
    }];
    description.configuration = configuration;
    return [self configurePersistentStoreCoordinatorWithDescription:description error:error_p];
}

- (BOOL)configurePersistentStoreCoordinatorForURL:(NSURL *)storeURL
                                           ofType:(NSString *)fileType
                                            error:(NSError **)error
{
    // On 10.8+, the coordinator whinges but doesn't fail if you leave out NSReadOnlyPersistentStoreOption and the file turns out to be read-only. Supplying a value makes it fail with a (not very helpful) error when the store is read-only
    NSDictionary<NSString *,id> *options = @{
                              NSReadOnlyPersistentStoreOption : @(self.isInViewingMode)
                              };

    return [self configurePersistentStoreCoordinatorForURL:storeURL
                                                    ofType:fileType
                                        modelConfiguration:nil
                                              storeOptions:options
                                                     error:error];
}

- (NSString *)persistentStoreTypeForFileType:(NSString *)fileType { return NSSQLiteStoreType; }

- (BOOL)readAdditionalContentFromURL:(NSURL *)absoluteURL error:(NSError **)error; { return YES; }

- (id)additionalContentForURL:(NSURL *)absoluteURL saveOperation:(NSSaveOperationType)saveOperation error:(NSError **)error;
{
	// Need to hand back something so as not to indicate there was an error
    return [NSNull null];
}

- (BOOL)writeAdditionalContent:(id)content toURL:(NSURL *)absoluteURL originalContentsURL:(NSURL *)absoluteOriginalContentsURL error:(NSError **)error;
{
    return YES;
}

#pragma mark Core Data-Specific

- (BOOL)updateMetadataForPersistentStore:(NSPersistentStore *)store error:(NSError **)error;
{
    return YES;
}

#pragma mark Lifecycle

/* The following three methods implement a mechanism which defer any requested
closing of this document until any currently working Save or Save As
operation is completed.
 
 Without this mechanism, if the code in -closeNow is in -close as it was before
 I fixed this, and if -close is invoked while saving is in progress, saving
 may produce the following rather surprising error (with underlying errors):
 
 code 478202 in domain: BSManagedDocumentErrorDomain
 Failed regular writing

 code: 478206 in domain: BSManagedDocumentErrorDomain
 Failed creating package directories

 code: 516 in domain: NSCocoaErrorDomain
 The file “xxx” couldn’t be saved in the folder “yyy” because a file with the
 same name already exists.

 code: 17 in domain: NSPOSIXErrorDomain
 The operation couldn’t be completed. File exists
 
 This occurs because the _store ivar may be set to nil before the code in the
 so-called "worker block" runs.  That code will presume that this must be a new
 document, and the resulting attempt to create new package directories will
 fail because that code (wisely, to prevent data on disk from being
 overwritten) passes withIntermediateDirectories:NO when invoking NSFileManager
 to do these creations.
 
 This mechanism is obviously important if we are, as we do by default, use
 asynchronous saving (see -canAsynchronouslyWriteToURL::), because the error
 will probably occur every time.  But it is also important (maybe even more
 important) otherwise, because in macOS 10.7+, -[NSDocument saveDocument:]
 always returns immediately, even if a subclass has opted *out* of asynchronous
 saving.  Saving is in fact merely "less asynchronous", and the error will
 occur only *sometimes*.
 */

- (void)close
{
    if (self.isSaving) {
        self.shouldCloseWhenDoneSaving = YES;
    }
    else
    {
        [self closeNow];
    }
}

- (void)signalDoneAndMaybeClose
{
    self.isSaving = NO;

    if (self.shouldCloseWhenDoneSaving)
    {
        [self closeNow];

        /* The following probably has no effect, but is for good practice. */
        self.shouldCloseWhenDoneSaving = NO;
    }
}

- (void)closeNow
{
    NSError *error = nil;
    if (![self removePersistentStoreWithError:&error])
        NSLog(@"Unable to remove persistent store before closing: %@", error);
    
    /* We do a main thread dance here because, if asynchronous saving is
     enabled, super -[NSDocument close] will usually close a document window,
     which will probably send -windowWillClose to a window controller, which
     may need to clean up some stuff in the user interface that probably needs
     to be done on the main thread.  At least, it does in my (Jerry) apps.  */
    if (NSThread.isMainThread)
    {
        [super close];
    }
    else
    {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [super close];
        });
    }
    [self deleteAutosavedContentsTempDirectory];
}

// It's simpler to wrap the whole method in a conditional test rather than using a macro for each line.
#if ! __has_feature(objc_arc)
- (void)dealloc;
{
    [_managedObjectModel release];
    [_container release];
    [_autosavedContentsTempDirectoryURL release];
    
    // _additionalContent is unretained so shouldn't be released here
    
    [super dealloc];
}
#endif


#pragma mark Reading Document Data

- (BOOL)removePersistentStoreWithError:(NSError **)outError {
    __block BOOL result = YES;
    __block NSError * error = nil;
    if (!self.isCoordinatorConfigured)
        return YES;
    
    NSPersistentStoreCoordinator *coordinator = self.coordinator;
    NSPersistentStore *store = self.store;
    
    [coordinator performBlockAndWait:^{
        result = [coordinator removePersistentStore:store error:&error];
#if !__has_feature(objc_arc)
        [error retain];
#endif
    }];
    
#if !__has_feature(objc_arc)
    [error autorelease];
#endif
    
    if (!result && outError) {
        *outError = error;
    }
    
    return result;
}

- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
    // Preflight the URL
    //  A) If the file happens not to exist for some reason, Core Data unhelpfully gives "invalid file name" as the error. NSURL gives better descriptions
    //  B) When reverting a document, the persistent store will already have been removed by the time we try adding the new one (see below). If adding the new store fails that most likely leaves us stranded with no store, so it's preferable to catch errors before removing the store if possible
    if (![absoluteURL checkResourceIsReachableAndReturnError:outError]) return NO;
    
    
    // If have already read, then this is a revert-type affair, so must reload data from disk
    if (self.isCoordinatorConfigured)
    {
        if (!NSThread.isMainThread) {
            [NSException raise:NSInternalInconsistencyException format:@"%@: I didn't anticipate reverting on a background thread!", NSStringFromSelector(_cmd)];
        }
        
        // NSPersistentDocument states: "Revert resets the document’s managed object context. Objects are subsequently loaded from the persistent store on demand, as with opening a new document."
        // I've found for atomic stores that -reset only rolls back to the last loaded or saved version of the store; NOT what's actually on disk
        // To force it to re-read from disk, the only solution I've found is removing and re-adding the persistent store
        if (![self removePersistentStoreWithError:outError])
            return NO;
    }
    
    
    // Setup the store
    // If the store happens not to exist, because the document is corrupt or in the wrong format, -configurePersistentStoreCoordinatorForURL:… will create a placeholder file which is likely undesirable! The only way to avoid that that I can see is to preflight the URL. Possible race condition, but not in any truly harmful way
    NSURL *storeURL = [[self class] persistentStoreURLForDocumentURL:absoluteURL];
    if (![storeURL checkResourceIsReachableAndReturnError:outError])
    {
        // The document architecture presents such an error as "file doesn't exist", which makes no sense to the user, so customize it
        if (outError && [*outError code] == NSFileReadNoSuchFileError && [[*outError domain] isEqualToString:NSCocoaErrorDomain])
        {
            *outError = [NSError errorWithDomain:NSCocoaErrorDomain
                                            code:NSFileReadCorruptFileError
                                        userInfo:@{ NSUnderlyingErrorKey : *outError }];
        }
        
        return NO;
    }
    
    BOOL result = [self configurePersistentStoreCoordinatorForURL:storeURL
                                                           ofType:typeName
                                                            error:outError];
    
    if (result)
    {
        result = [self readAdditionalContentFromURL:absoluteURL error:outError];
    }
    
    return result;
}

- (NSPersistentStoreCoordinator*)coordinator {
    return self.persistentContainer.persistentStoreCoordinator;
}

- (NSPersistentStore *)store {
    return self.persistentContainer.persistentStoreCoordinator.persistentStores.firstObject;
}

#pragma mark Writing Document Data

- (BOOL)makeWritingBlockForURL:(NSURL *)url ofType:(NSString *)typeName saveOperation:(NSSaveOperationType)saveOperation error:(NSError **)outError;
{
    // NSAssert([NSThread isMainThread], @"Somehow -%@ has been called off of the main thread (operation %u to: %@)", NSStringFromSelector(_cmd), (unsigned)saveOperation, [url path]);
    // See Note JK20180125 below.
    
    BOOL __block ok = YES;

    // Grab additional content that a subclass might provide
    if (outError) *outError = nil;  // unusually for me, be forgiving of subclasses which forget to fill in the error
    id additionalContent = [self additionalContentForURL:url saveOperation:saveOperation error:outError];
    if (!additionalContent)
    {
        if (outError) NSAssert(*outError != nil, @"-additionalContentForURL:saveOperation:error: failed with a nil error");
        [self signalDoneAndMaybeClose];
        ok = NO;
    }
    
#if __has_feature(objc_arc)
    __weak typeof(self) welf = self;
#else
    // __weak was meaningless in non-ARC; generates a compiler warning
    BSManagedDocument* welf = self;
#endif
    
    self.writingBlock = ^(NSURL *url, NSSaveOperationType saveOperation, NSURL *originalContentsURL, NSError **error) {
        
        // For the first save of a document, create the folders on disk before we do anything else
        // Then setup persistent store appropriately
        BOOL result = YES;
        NSURL *storeURL = [welf.class persistentStoreURLForDocumentURL:url];
        
        if (!welf.isCoordinatorConfigured)
        {
            result = [welf createPackageDirectoriesAtURL:url
                                                  ofType:typeName
                                        forSaveOperation:saveOperation
                                     originalContentsURL:originalContentsURL
                                                   error:error];
            if (!result)
            {
                [welf spliceErrorWithCode:478206
                     localizedDescription:@"Failed creating package directories"
                            likelyCulprit:url
                             intoOutError:error];
                [welf signalDoneAndMaybeClose];
                return NO;
            }
            
            result = [welf configurePersistentStoreCoordinatorForURL:storeURL
                                                              ofType:typeName
                                                               error:error];
            if (!result)
            {
                [welf spliceErrorWithCode:478207
                     localizedDescription:@"Failed to configure PSC"
                            likelyCulprit:storeURL
                             intoOutError:error];
                [welf signalDoneAndMaybeClose];
                return NO;
            }
        }
        else if (saveOperation == NSSaveAsOperation)
        {
            // Copy the whole package to the new location, not just the store content
            if (![welf writeBackupToURL:url error:error])
            {
                [welf spliceErrorWithCode:478208
                     localizedDescription:@"Failed writing backup file"
                            likelyCulprit:url
                             intoOutError:error];
                [welf signalDoneAndMaybeClose];
                return NO;
            }
        }
        else if (saveOperation != NSSaveOperation && saveOperation != NSAutosaveInPlaceOperation)
                {
                    if (![storeURL checkResourceIsReachableAndReturnError:NULL])
                    {
                        result = [welf createPackageDirectoriesAtURL:url
                                                              ofType:typeName
                                                    forSaveOperation:saveOperation
                                                 originalContentsURL:originalContentsURL
                                                               error:error];
                        if (!result)
                        {
                            [welf spliceErrorWithCode:478215
                                 localizedDescription:@"Failed creating package directories for non-regular save"
                                        likelyCulprit:url
                                         intoOutError:error];
                            [welf signalDoneAndMaybeClose];
                            return NO;
                        }

                        // Fake a placeholder file ready for the store to save over
                        result = [[NSData data] writeToURL:storeURL options:0 error:error];
                        if (!result)
                        {
                            [welf spliceErrorWithCode:478216
                                 localizedDescription:@"Failed faking placeholder"
                                        likelyCulprit:storeURL
                                         intoOutError:error];
                            [welf signalDoneAndMaybeClose];
                            return NO;
                        }
                    }
                }
        
#if !__has_feature(objc_arc)
        [welf retain];
#endif
        // Right, let's get on with it!
        if (![welf writeStoreContentToURL:storeURL error:error])
        {
            [welf spliceErrorWithCode:478220
                 localizedDescription:@"Failed writeStoreContentToURL"
                        likelyCulprit:storeURL
                         intoOutError:error];

            [welf signalDoneAndMaybeClose];
#if !__has_feature(objc_arc)
            [welf release];
#endif
            return NO;
        }
        
        /* 2020-May-17  Damn.  Still seeing crashes here
         once a week or so when running in Xcode debugger in non-ARC, possibly
         after letting a dialog sit without responding for several minutes,
         or maybe just letting the app sit idle for a few minutes.
         I have seen two types of crashes:
         
         1.  Unexplained EXC_BAD_ACCESS
         2.  -[CAContextImpl writeAdditionalContent:toURL:originalContentsURL:error:]: unrecognized selector sent to instance …
         
         Crash type number 2 implies that the weak self `welf` is gone and the
         message is being sent to some other object which took its memory, but
         why does it crash *here* when, in the lines above, many messages are
         sent to `welf` and none of those ever crash?
         
         Maybe the call to -writeStoreContentToURL:error: waits for the save
         to happen, and that is when `welf` disappears.  To save time, I am
         going to skip the analysis and try to fix this with something that
         should do no harm in any case: Send `welf` a -retain above and balance
         with a -release before each of the two `return` statements, below.
         If you see no further comment here for the rest of year 2020, that
         means that this fix worked.  It does make sense, at least :)
         
         2020-Jul-14  Still making crashes here, with macOS 11 Beta 2.
         Looks like the same as crash type 2 above, but welf got smashed
         by a different object:
         -[_NSCoreDataTaggedObjectID writeAdditionalContent:toURL:originalContentsURL:error:]: unrecognized selector sent to instance
         */
        result = [welf writeAdditionalContent:additionalContent toURL:url originalContentsURL:originalContentsURL error:error];
        if (result)
        {
            // Update package's mod date. Two circumstances where this is needed:
            //  user requests a save when there's no changes; SQLite store doesn't bother to touch the disk in which case
            //  saving where +storeContentName is non-nil; that folder's mod date updates, but the overall package needs prompting
            // Seems simplest to just apply this logic all the time
            NSError *error;
            if (![url setResourceValue:[NSDate date] forKey:NSURLContentModificationDateKey error:&error])
            {
                NSLog(@"Updating package mod date failed: %@", error);  // not critical, so just log it
            }
        }
        else
        {
            [welf spliceErrorWithCode:478217
                 localizedDescription:@"Failed to get on with writing"
                        likelyCulprit:url
                         intoOutError:error];
            [welf signalDoneAndMaybeClose];
#if !__has_feature(objc_arc)
            [welf release];
#endif
            return NO;
        }
        
        // Restore persistent store URL after Save To-type operations. Even if save failed (just to be on the safe side)
        if (saveOperation == NSSaveToOperation)
        {
            if (![welf setURLForPersistentStoreUsingStoreURL:originalContentsURL])
            {
                NSLog(@"Failed to reset store URL after Save To Operation");
            }
        }
        
        [welf signalDoneAndMaybeClose];
#if !__has_feature(objc_arc)
        [welf release];
#endif
        return result;
    };
    
    return ok;
}

- (BOOL)createPackageDirectoriesAtURL:(NSURL *)url
                               ofType:(NSString *)typeName
                     forSaveOperation:(NSSaveOperationType)saveOperation
                  originalContentsURL:(NSURL *)originalContentsURL
                                error:(NSError **)error;
{
    // Create overall package
    NSDictionary *attributes = [self fileAttributesToWriteToURL:url
                                                         ofType:typeName
                                               forSaveOperation:saveOperation
                                            originalContentsURL:originalContentsURL
                                                          error:error];
    if (!attributes) return NO;
    
    BOOL result = NO;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    result = [fileManager createDirectoryAtURL:url
                   withIntermediateDirectories:NO
                                    attributes:attributes
                                         error:error];
    if (!result)
    {
        [self spliceErrorWithCode:478219
             localizedDescription:@"File Manager failed to create package directory"
                    likelyCulprit:url
                     intoOutError:error];
        return NO;
    }

    // Create store content folder too
    NSString *storeContent = self.class.storeContentName;
    if (storeContent)
    {
        NSURL *storeContentURL = [url URLByAppendingPathComponent:storeContent];
        result = [fileManager createDirectoryAtURL:storeContentURL
                       withIntermediateDirectories:NO
                                        attributes:attributes
                                             error:error];

        if (!result)
        {
            [self spliceErrorWithCode:478218
                 localizedDescription:@"File Manager failed to create store content subdirectory"
                        likelyCulprit:storeContentURL
                         intoOutError:error];
            return NO;
        }
    }
    
    // Set the bundle bit for good measure, so that docs won't appear as folders on Macs without your app installed. Don't care if it fails
    [self setBundleBitForDirectoryAtURL:url];
    
    return YES;
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation completionHandler:(void (^)(NSError *))completionHandler
{
    // Can't touch _additionalContent etc. until existing save has finished
    // At first glance, -performActivityWithSynchronousWaiting:usingBlock: seems the right way to do that. But turns out:
    //  * super is documented to use -performAsynchronousFileAccessUsingBlock: internally
    //  * Autosaving (as tested on 10.7) is declared to the system as *file access*, rather than an *activity*, so a regular save won't block the UI waiting for autosave to finish
    //  * If autosaving while quitting, calling -performActivity… here results in deadlock
    [self performAsynchronousFileAccessUsingBlock:^(void (^fileAccessCompletionHandler)(void)) {

        NSError* shouldAbortError = nil;
        
        if (self.writingBlock != nil) {
            NSLog(@"Warning 382-6733 Aborting save because another is already in progress.");
            shouldAbortError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:NSUserCancelledError
                                               userInfo:nil];
        } else {
            [self makeWritingBlockForURL:url ofType:typeName saveOperation:saveOperation error:&shouldAbortError];

            BOOL noWritingBlock = (self.writingBlock == nil);
            if (noWritingBlock) {
                NSLog(@"Warning 382-6735 Aborting save cuz no writingBlock: %@", self);
            }

            if (noWritingBlock)
            {
                // In either of these exceptional cases, abort the save.

                // The docs say "be sure to invoke super", but by my understanding it's fine not to if it's because of a failure, as the filesystem hasn't been touched yet.
                self.writingBlock = nil;
                if (!shouldAbortError) {
                    shouldAbortError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                           code:NSUserCancelledError
                                                       userInfo:nil];
                }
            }
        }
            
        if (shouldAbortError) {
            if (NSThread.isMainThread)
            {
                fileAccessCompletionHandler();
                if (completionHandler) completionHandler(shouldAbortError);
            }
            else
            {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    fileAccessCompletionHandler();
                    if (completionHandler) completionHandler(shouldAbortError);
                });
            }
            return;
        }
        
        // Kick off async saving work
        [super saveToURL:url ofType:typeName forSaveOperation:saveOperation completionHandler:^(NSError *error) {
            
            // If the save failed, it might be an error the user can recover from.
			// e.g. the dreaded "file modified by another application"
			// NSDocument handles this by presenting the error, which includes recovery options
			// If the user does choose to Save Anyway, the doc system leaps straight onto secondary thread to
			// accomplish it, without calling this method again.
			// Thus we want to hang onto _writingBlock until the overall save operation is finished, rather than
			// just this method. The best way I can see to do that is to make the cleanup its own activity, so
			// it runs after the end of the current one. Unfortunately there's no guarantee anyone's been
            // thoughtful enough to register this as an activity (autosave, I'm looking at you), so only rely
            // on it if there actually is a recoverable error
			if (error.recoveryAttempter)
            {
                [self performActivityWithSynchronousWaiting:NO usingBlock:^(void (^activityCompletionHandler)(void)) {
                    
                    self.writingBlock = nil;
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        activityCompletionHandler();
                    });
                }];
            }
            else
            {
                self.writingBlock = nil;
            }
			
			
            // Clean up our custom autosaved contents directory if appropriate
            if (!error &&
                (saveOperation == NSSaveOperation || saveOperation == NSAutosaveInPlaceOperation || saveOperation == NSSaveAsOperation))
            {
                [self deleteAutosavedContentsTempDirectory];
            }
			
			// And can finally declare we're done
            if (NSThread.isMainThread)
            {
                fileAccessCompletionHandler();
                if (completionHandler) completionHandler(error);
            }
            else
            {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    fileAccessCompletionHandler();
                    if (completionHandler) completionHandler(error);
                });
            }
        }];
    }];
}

- (BOOL)spliceErrorWithCode:(NSInteger)code
       localizedDescription:(NSString*)localizedDescription
              likelyCulprit:(id)likelyCulprit
               intoOutError:(NSError**)outError
{
    if (outError)
    {
        NSMutableDictionary<NSErrorUserInfoKey, id> *mutant = [NSMutableDictionary new];
        mutant[NSLocalizedDescriptionKey] = localizedDescription;
        if (!*outError) {
            *outError = [NSError errorWithDomain:BSManagedDocumentErrorDomain
                                                          code:478230
                                     userInfo:@{NSLocalizedDescriptionKey : @"Caller did not provide an underlying error"}];
        }
        mutant[NSUnderlyingErrorKey] = *outError;
        mutant[@"Likely Culprit"] = likelyCulprit;
        NSDictionary<NSErrorUserInfoKey, id> *userInfo = [mutant copy];
        NSError* overlyingError = [NSError errorWithDomain:BSManagedDocumentErrorDomain
                                                      code:code
                                                  userInfo:userInfo];
        *outError = overlyingError;
#if ! __has_feature(objc_arc)
        [mutant release];
        [userInfo release];
#endif
    }
    
    /* We never use this return value.  However, the stupid static analyzer
     insists that any method taking an NSError** parameter must return a BOOL. */
    return YES;
}


/*	Regular Save operations can write directly to the existing document since Core Data provides atomicity for us
 */
- (BOOL)writeSafelyToURL:(NSURL *)absoluteURL
				  ofType:(NSString *)typeName
		forSaveOperation:(NSSaveOperationType)saveOperation
				   error:(NSError **)outError
{
    BOOL result = NO ;
    BOOL done = NO ;

    // It's possible subclassers support more file types than the Core Data package-based one
    // BSManagedDocument supplies. e.g. an alternative format for exporting, say. If so, they don't
    // want our custom logic kicking in when writing it, so test for that as best we can.
    // https://github.com/karelia/BSManagedDocument/issues/36#issuecomment-91773320
	if ([NSWorkspace.sharedWorkspace type:self.fileType conformsToType:typeName]) {
        
		// At this point, we've either captured all document content, or are writing on the main thread, so it's fine to unblock the UI
		[self unblockUserInteraction];
		
        // Note that duplicating an unsaved document takes place as an AutosaveElsewhere.
        // So if we're autosaving-elsewhere to a location that's not our own autosavedContentsFileURL,
        // skip this step and go to the "regular channels" code path outside this block
        if (saveOperation == NSSaveOperation || saveOperation == NSAutosaveInPlaceOperation ||
            saveOperation == NSAutosaveElsewhereOperation) {
            NSURL *backupURL = nil;
            NSURL *autosavedContentsFileURL = self.autosavedContentsFileURL;
            
			// As of 10.8, need to make a backup of the document when saving in-place
			if ((saveOperation == NSSaveOperation || saveOperation == NSAutosaveInPlaceOperation) &&
				self.class.preservesVersions)			// otherwise backupURL has a different meaning
			{
				backupURL = self.backupFileURL;
				if (backupURL)
				{
					if (![self writeBackupToURL:backupURL error:outError])
					{
						// If backup fails, seems it's our responsibility to clean up
						NSError *error;
						if (![NSFileManager.defaultManager removeItemAtURL:backupURL error:&error])
						{
							NSLog(@"Unable to cleanup after failed backup: %@", error);
						}
						
                        [self spliceErrorWithCode:478201
                             localizedDescription:@"Failed writing backup prior to writing"
                                    likelyCulprit:backupURL
                                     intoOutError:outError];

                        return NO;
					}
				}
            } else if (saveOperation == NSAutosaveElsewhereOperation) {
                // "Autosave Elsewhere" is abused by NSDocument for all kinds of things
                if (!self.mostRecentlySavedFileURL) {
                    // If an autosave is forced early on in the document life cycle, the autosavedContentsFileURL
                    // might not be set. Go ahead and set it here so that NSDocument won't attempt to give the
                    // document a second autosave URL.
                    self.autosavedContentsFileURL = absoluteURL;
                } else if (!self.autosavedContentsFileURL && self.hasUnautosavedChanges) {
                    // This looks like NSDocument is trying to preserve a document version prior to a Revert.
                    self.autosavedContentsFileURL = absoluteURL;
                } else if (![absoluteURL isEqual:self.autosavedContentsFileURL]) {
                    // We're supposed to blast a copy out somewhere else e.g.:
                    // * A temporary Share location
                    // * A Duplicate location in the autosave folder
                    // We ensured the disk copy is up-to-date earlier inside the overrides to
                    // duplicateAndReturnError: and shareDocumentWithSharingService:completionHandler:
                    self.writingBlock = ^(NSURL *url, NSSaveOperationType saveOperation, NSURL *originalContentsURL, NSError **error) {
                        return [self writeBackupToURL:url error:error];
                    };
                }
            }
			
            // NSDocument attempts to write a copy of the document out at a temporary location.
            // Core Data cannot support this, so we override it to save directly.
            // The following call is synchronous.  It does not return until saving is all done.
            result = [self writeToURL:absoluteURL
                               ofType:typeName
                     forSaveOperation:saveOperation
                  originalContentsURL:self.fileURL
                                error:outError];
            
            self.writingBlock = nil; // May have been set above
            
            if (!result)
            {
                [self spliceErrorWithCode:478202
                     localizedDescription:@"Failed regular writing"
                            likelyCulprit:absoluteURL
                             intoOutError:outError];

                // Clean up backup if one was made
                // If the failure was actualy NSUserCancelledError thanks to
                // autosaving being implicitly cancellable and a subclass deciding
                // to bail out, this HAS to be done otherwise the doc system will
                // weirdly complain that a file by the same name already exists
                NSError *error;
                if (backupURL && ![NSFileManager.defaultManager removeItemAtURL:backupURL error:&error]) {
                    NSLog(@"Unable to remove backup after failed write: %@", error);
                }
                
                // The -write… method maybe wasn't to know that it's writing to the live document, so might have modified it. #179730
                // We can patch up a bit by updating modification date so user doesn't get baffling document-edited warnings again!
                // Note that some file systems don't support mod date so we need to test that it's not nil
                NSDate *modDate;
                if ([absoluteURL getResourceValue:&modDate forKey:NSURLContentModificationDateKey error:NULL] && modDate)
                {
                    self.fileModificationDate = modDate;
                }
                
                // Restore the previous autosavedContentsFileURL if saving failed
                if (saveOperation == NSAutosaveElsewhereOperation) {
                    self.autosavedContentsFileURL = autosavedContentsFileURL;
                }
            }
            
            done = YES;
        }
    }
    
    if (!done) {
        // Other situations are basically fine to go through the regular channels
        result = [super writeSafelyToURL:absoluteURL
                                  ofType:typeName
                        forSaveOperation:saveOperation
                                   error:outError];
        if (!result) {
            [self spliceErrorWithCode:478203
                 localizedDescription:@"Failed other writing"
                        likelyCulprit:absoluteURL
                        intoOutError:outError];
        }
    }
    
    if (result) {
        NSNotification* note = [[NSNotification alloc] initWithName:BSManagedDocumentDidSaveNotification
                                                             object:self
                                                           userInfo:nil] ;
        [NSNotificationCenter.defaultCenter performSelectorOnMainThread:@selector(postNotification:)
                                                             withObject:note
                                                          waitUntilDone:NO] ;
#if ! __has_feature(objc_arc)
        [note release];
#endif
                                                            
    }
    
    return result ;
}

- (BOOL)writeBackupToURL:(NSURL *)backupURL error:(NSError **)outError;
{
    NSURL *source = self.mostRecentlySavedFileURL;
    /* In case the user inadvertently clicks File > Duplicate on a new
     document which has not been saved yet, source will be nil, so
     we check for that to avoid a subsequent NSFileManager exception. */
    if (!source)
        return YES;

    /* The following also copies any additional content in the package. */
    return [NSFileManager.defaultManager copyItemAtURL:source toURL:backupURL error:outError];
}

- (BOOL)writeToURL:(NSURL *)inURL
            ofType:(NSString *)typeName
  forSaveOperation:(NSSaveOperationType)saveOp
originalContentsURL:(NSURL *)originalContentsURL
             error:(NSError **)outError
{
    if (!self.writingBlock)
    {
        /* We are being called for the first time in the current write
         operation. */
        if (![self makeWritingBlockForURL:inURL ofType:typeName saveOperation:saveOp error:outError]) {
            [self spliceErrorWithCode:478204
                 localizedDescription:@"Failed making _writingBlock"
                        likelyCulprit:inURL
                         intoOutError:outError];
            return NO;
        }
        
        /* The following apparently recursive call to ourself will only occur
         once, because self.writingBlock is no longer nil and the branch in
         which we are now in will not execute in the sequel. */
        BOOL result = [self writeToURL:inURL ofType:typeName forSaveOperation:saveOp originalContentsURL:originalContentsURL error:outError];
        if (!result) {
            [self spliceErrorWithCode:478205
                 localizedDescription:@"Failed writing for real"
                         likelyCulprit:inURL
                         intoOutError:outError];
        }
        
        /* The self.writingBlock has executed and is no longer needed.
         Furthermore, we must clear it to nil in preparation for any subsequent
         write operation. */
        self.writingBlock = nil;
        return result;
    }
    
    // The following invocation of _writingBlock does the actual work of saving
    BOOL ok = self.writingBlock(inURL, saveOp, originalContentsURL, outError);
    return ok;
}

- (void)setBundleBitForDirectoryAtURL:(NSURL *)url;
{
    NSError *error;
    if (![url setResourceValue:@YES forKey:NSURLIsPackageKey error:&error])
    {
        NSLog(@"Error marking document as a package: %@", error);
    }
}

- (void)performBlockAndWaitOnViewContext:(void(^)(NSManagedObjectContext *))block {
    NSManagedObjectContext *savingContext = self.managedObjectContext;

    // The returned context (the container's .viewContext) needs access to the main thread to do its work.
    // If we're on the main thread, go ahead and do it. If not, we may need to break out of the main thread's
    // performSynchronousFileAccessUsingBlock: (e.g. the fakeSynchronousAutosave method invoked by File > Duplicate).
    // continueAsynchronousWorkOnMainThreadUsingBlock: lets us slip in some work on the main thread, but it
    // returns immediately, so use a semaphore to ensure the save is complete before this function returns.
    if (NSThread.isMainThread) {
        [savingContext performBlockAndWait:^{
            block(savingContext);
        }];
    } else {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [self continueAsynchronousWorkOnMainThreadUsingBlock:^{
            [savingContext performBlockAndWait:^{
                block(savingContext);
            }];
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
#if ! __has_feature(objc_arc)
        dispatch_release(semaphore);
#endif
    }
}

/* This method returns BOOL YES to silence a stupid compiler warning in
 Xcode 12.5 > Analyze. */
- (BOOL)fixIfCorruptIndex:(NSError **)error {
    if (error) {
        if ([(*error).domain isEqualToString:NSSQLiteErrorDomain] && ((*error).code == 779)) {
            /* Corrupt index in the sqlite database, which maybe we can
             fix.  I have seen this work in the field at least once.
             See https://www.sqlite.org/rescode.html#corrupt_index */
            NSString* sqlitePath = @"/usr/bin/sqlite3";
            if ([[NSFileManager defaultManager] fileExistsAtPath:sqlitePath]) {
                NSString* path = self.store.URL.path;
                NSTask* task = [NSTask new];
                task.launchPath = sqlitePath;
                task.arguments = @[path, @"reindex"];
                [task launch];
                [task waitUntilExit];
                int status = [task terminationStatus];
                NSString* fixResult;
                NSString* recoverySuggestion = nil;
                if (status == 0) {
                    fixResult = @"We maybe fixed it.";
                    recoverySuggestion = @"Try to save the document again.";
                } else {
                    fixResult = [NSString stringWithFormat:
                                 @"We tried but supposedly failed to fix it by running 'sqlite3 ... reindex'.  Got status %ld, expected 0",
                                 (long)status];
                }
                NSString* desc = [NSString stringWithFormat:@"Document was found to have a corrupt SQLite index. %@", fixResult];
                NSMutableDictionary* userInfo = [NSMutableDictionary new];
                [userInfo setObject:desc
                             forKey:NSLocalizedDescriptionKey];
                [userInfo setValue:*error
                            forKey:NSUnderlyingErrorKey];
                [userInfo setValue:recoverySuggestion
                            forKey:NSLocalizedRecoverySuggestionErrorKey];
                *error = [NSError errorWithDomain:BSManagedDocumentErrorDomain
                                             code:478230
                                         userInfo:userInfo];
#if ! __has_feature(objc_arc)
                [task release];
                [userInfo release];
#endif
            }
        }
    }
    
    return YES;
}

- (BOOL)writeStoreContentToURL:(NSURL *)storeURL error:(NSError **)error;
{
    // First update metadata
    __block BOOL result = [self updateMetadataForPersistentStore:self.store error:error];
    if (!result) return NO;
    
    [self unblockUserInteraction];

    // Preflight the save since it tends to crash upon failure pre-Mountain Lion. rdar://problem/10609036
    NSNumber *writable = nil;
    if (![storeURL getResourceValue:&writable forKey:NSURLIsWritableKey error:error])
        return NO;
    
    // Ensure store is writeable and saving to right location
    if (!writable.boolValue || ![self setURLForPersistentStoreUsingStoreURL:storeURL]) {
        if (error) {
            // Generic error. Doc/error system takes care of supplying a nice generic message to go with it
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:nil];
        }
        
        return NO;
    }
    
    // On 10.12+ saving on the viewContext goes directly to disk. There is no parentContext.
    [self performBlockAndWaitOnViewContext:^(NSManagedObjectContext *ctx) {
        result = [ctx save:error];
        [self fixIfCorruptIndex:error];

#if ! __has_feature(objc_arc)
        // Errors need special handling to guarantee surviving crossing the block. http://www.mikeabdullah.net/cross-thread-error-passing.html
        if (!result && error) [*error retain];
#endif
    }];
        
#if ! __has_feature(objc_arc)
    if (!result && error) [*error autorelease]; // tidy up since any error was retained on worker thread
#endif
    return result;
}

#pragma mark NSDocument

+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)typeName { return YES; }

- (BOOL)isEntireFileLoaded { return NO; }

- (BOOL)canAsynchronouslyWriteToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation;
{
    // In order to provide immediate access to an NSManagedObjectContext from the main thread, we need
    // to force an autosave so that the NSPersistentContainer has a backing store, without which attempts
    // to save will fail. If asynchronous saving is enabled, the save itself will occur on a background
    // thread – but the container's viewContext needs access to the main thread in order to save, resulting
    // in a deadlock, since the main thread is still waiting for the initial autosave to complete. To prevent the
    // deadlock, disable asynchronous writing (below) until the container has a backing store.
    
    // Since the viewContext uses the main queue, it's not clear how much benefit is provided by asynchronous
    // saving anyway, as the background thread will just block while waiting for the main thread to perform its save.
    // There will still be benefits for document subclasses that store "additional content" in the document package,
    // see the addtionalContent* methods of this class. I believe that as long as BSManagedDocument is providing subclasses
    // with access to the container's viewContext, then it is the viewContext that will have to be saved, and thus
    // we'll always need main thread access for saving even with "asynchronous" writing turned on. It's possible that
    // we could re-architect things to provide access to a background context instead, but client applications will (in
    // my understanding) to have wrap all of their model interactions in performBlocks for the marginal benefit of enabling
    // fully aysnchronous writing.
    
    // So: Enable async writing by default (after the initial write has occurred), but note that it may still end up blocking
    // the main UI thread. I personally prefer to turn off async entirely (by overriding this method to return NO) as async
    // writing has been the source of a number of subtle race conditions in the past. -EMM 2021-01-02
    return self.isCoordinatorConfigured;
}

- (void)setFileURL:(NSURL *)absoluteURL
{
    // Mark persistent store as moved
    if (!self.autosavedContentsFileURL)
    {
        [self setURLForPersistentStoreUsingFileURL:absoluteURL];
    }
    
    [super setFileURL:absoluteURL];
}

- (BOOL)setURLForPersistentStoreUsingStoreURL:(NSURL *)storeURL {
    if (!self.isCoordinatorConfigured) return NO;

    NSPersistentStoreCoordinator *coordinator = self.coordinator;
    NSPersistentStore *store = self.store;
    
    __block BOOL result = NO;
    [coordinator performBlockAndWait:^{
        result = [coordinator setURL:storeURL forPersistentStore:store];
    }];
    return result;
}

- (void)setURLForPersistentStoreUsingFileURL:(NSURL *)absoluteURL;
{
    if (!self.isCoordinatorConfigured) return;
    
    NSURL *storeURL = [[self class] persistentStoreURLForDocumentURL:absoluteURL];
    
    if (![self setURLForPersistentStoreUsingStoreURL:storeURL])
    {
        NSLog(@"Unable to set store URL: %@", storeURL);
    }
}

#pragma mark Autosave

/*  Enable autosave-in-place and versions browser, override if you don't want them
 */
+ (BOOL)autosavesInPlace { return YES; }
+ (BOOL)preservesVersions { return self.autosavesInPlace; }

- (void)setAutosavedContentsFileURL:(NSURL *)absoluteURL;
{
    [super setAutosavedContentsFileURL:absoluteURL];
    
    // Point the store towards the most recent known URL
    absoluteURL = self.mostRecentlySavedFileURL;
    if (absoluteURL) [self setURLForPersistentStoreUsingFileURL:absoluteURL];
}

- (NSURL *)mostRecentlySavedFileURL;
{
    // Before the user chooses where to place a new document, it has an autosaved URL only
    return self.autosavedContentsFileURL ?: self.fileURL;
}

/*
 When asked to autosave an existing doc elsewhere, we do so via an
 intermedate, temporary copy of the doc. This code tracks that temp folder
 so it can be deleted when no longer in use.
 */

@synthesize autosavedContentsTempDirectoryURL = _autosavedContentsTempDirectoryURL;

- (void)deleteAutosavedContentsTempDirectory;
{
    NSURL *autosaveTempDir = self.autosavedContentsTempDirectoryURL;
    if (autosaveTempDir)
    {
#if ! __has_feature(objc_arc)
        [[autosaveTempDir retain] autorelease];
#endif
        self.autosavedContentsTempDirectoryURL = nil;
        
        NSError *error;
        if (![NSFileManager.defaultManager removeItemAtURL:autosaveTempDir error:&error])
        {
            NSLog(@"Unable to remove temporary directory: %@", error);
        }
    }
}

- (IBAction)saveDocument:(id)sender {
    self.isSaving = YES;
    [super saveDocument:sender];
}


#pragma mark Reverting Documents

- (BOOL)revertToContentsOfURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError;
{
    // Tear down old windows. Wrap in an autorelease pool to get us much torn down before the reversion as we can
    @autoreleasepool
    {
    NSArray<NSWindowController *> *controllers = [self.windowControllers copy]; // we're sometimes handed underlying mutable array. #156271
    for (NSWindowController *aController in controllers)
    {
        [self removeWindowController:aController];
        [aController close];
    }
#if ! __has_feature(objc_arc)
    [controllers release];
#endif
    }


    @try
    {
        if (![super revertToContentsOfURL:absoluteURL ofType:typeName error:outError]) return NO;
        [self deleteAutosavedContentsTempDirectory];
        
        return YES;
    }
    @finally
    {
        [self makeWindowControllers];
        
        // Don't show the new windows if in the middle of reverting due to the user closing document
        // and choosing to revert changes. The new window bouncing on screen looks wrong, and then
        // stops the document closing properly (or at least appearing to have closed).
        // In theory I could not bother recreating the window controllers either. But the document
        // system seems to have the expectation that it can keep your document instance around in
        // memory after the revert-and-close, ready to re-use later (e.g. the user asks to open the
        // doc again). If that happens, the window controllers need to still exist, ready to be
        // shown.
        if (!_closing) [self showWindows];
    }
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void *)contextInfo {
    // Track if in the middle of closing
    _closing = YES;
    
    void (^completionHandler)(BOOL) = ^(BOOL shouldClose) {
        if (delegate) {
            /* Calls to objc_msgSend()  won't compile, by default, or projects
             "upgraded" by Xcode 8-9, due to fact that Build Setting
             "Enable strict checking of objc_msgSend Calls" is now ON.  See
             https://stackoverflow.com/questions/24922913/too-many-arguments-to-function-call-expected-0-have-3
             The result is, oddly, a Semantic Issue:
             "Too many arguments to function call, expected 0, have 5"
             I chose the answer by Sahil Kapoor, which allows me to leave
             the Build Setting ON and not fight with future Xcode updates. */
            id (*typed_msgSend)(id, SEL, id, BOOL, void*) = (void *)objc_msgSend;
            typed_msgSend(delegate, shouldCloseSelector, self, shouldClose, contextInfo);
        }
    };
    
    /*
     There may be a bug near here, or it may be in Veris 7:
     Click in menu: File > New Subject.
     Click the red 'Close' button.
     Next line will deadlock.
     Sending [self setChangeCount:NSChangeCleared] before that line does not help.
     To get rid of such a document (which will reappear on any subsequent launch
     due to state restoration), send here [self close].
     */
    [super canCloseDocumentWithDelegate:self
                    shouldCloseSelector:@selector(document:didDecideToClose:contextInfo:)
                            contextInfo:Block_copy((__bridge void *)completionHandler)];
}

- (void)document:(NSDocument *)document didDecideToClose:(BOOL)shouldClose contextInfo:(void *)contextInfo {
    _closing = NO;
    
    // Pass on to original delegate
    void (^completionHandler)(BOOL) = (__bridge void (^)(BOOL))(contextInfo);
    completionHandler(shouldClose);
    Block_release(contextInfo);
}

#pragma mark Duplicating and Sharing Documents

- (NSDocument *)duplicateAndReturnError:(NSError **)outError;
{
    if (outError) {
        *outError = nil;
    }
    /* The above is needed to prevent a up-stack crash in
     -spliceErrorWithCode:localizedDescription:likelyCulprit:intoOutError:
     because, apparently macOS passes *outError = garbage (but, oddly, only
     with ARC in macOS 10.15.)  Anyhow, initializing variables is always a
     good practice!  */
    
    // Accessing the MOC ensures a backing store exists
    (void)[self managedObjectContext];
    
    // Make sure copy on disk is up-to-date
    if (![self fakeSynchronousAutosaveAndReturnError:outError]) return nil;
    
    // Let super handle the overall duplication so it gets the window-handling
    // The writing itself occurs as an "autosave elsewhere" to somewhere other
    // than the autosavedContentsFileURL
    return [super duplicateAndReturnError:outError];
}

- (void)shareDocumentWithSharingService:(NSSharingService *)sharingService completionHandler:(void (^)(BOOL))completionHandler API_AVAILABLE(macos(10.13)) {
    // Accessing the MOC ensures a backing store exists
    (void)[self managedObjectContext];
    
    // Make sure copy on disk is up-to-date
    if (![self fakeSynchronousAutosaveAndReturnError:nil]) return completionHandler(NO);
    
    // As with file duplication, the actual save operation will be an "autosave elsewhere"
    [super shareDocumentWithSharingService:sharingService completionHandler:completionHandler];
}

/*  Approximates a synchronous version of -autosaveDocumentWithDelegate:didAutosaveSelector:contextInfo:    */
- (BOOL)fakeSynchronousAutosaveAndReturnError:(NSError **)outError;
{
    NSError* __block error = nil;
    
    // Kick off an autosave
    __block BOOL result = YES;
    [super autosaveWithImplicitCancellability:NO completionHandler:^(NSError *errorOrNil) {
        if (errorOrNil)
        {
            result = NO;
            error = [errorOrNil copy];  // in case there's an autorelease pool
        }
    }];
    
    // Somewhat of a hack: wait for autosave to finish
    [self performSynchronousFileAccessUsingBlock:^{ }];
    
#if ! __has_feature(objc_arc)
    [error autorelease];   // match the -copy above
#endif
    
    if (error && outError) {
        *outError = error ;
    }

    return result;
}

- (IBAction)saveDocumentAs:(id)sender {
    self.isSaving = YES;
    [super saveDocumentAs:sender];
}


#pragma mark Error Presentation

/*! we override willPresentError: here largely to deal with
 any validation issues when saving the document
 */
- (NSError *)willPresentError:(NSError *)inError
{
	NSError *result = nil;
    
    // customizations for NSCocoaErrorDomain
	if ( [inError.domain isEqualToString:NSCocoaErrorDomain] )
	{
		NSInteger errorCode = inError.code;
		
		// is this a Core Data validation error?
		if ( (NSValidationErrorMinimum <= errorCode) && (errorCode <= NSValidationErrorMaximum) )
		{
			// If there are multiple validation errors, inError will be a NSValidationMultipleErrorsError
			// and all the validation errors will be in an array in the userInfo dictionary for key NSDetailedErrorsKey
			NSArray<NSError *> *detailedErrors = inError.userInfo[NSDetailedErrorsKey];
			if (detailedErrors)
			{
				NSUInteger numErrors = detailedErrors.count;
				NSMutableString *errorString = [NSMutableString stringWithFormat:@"%lu validation errors have occurred.", (unsigned long)numErrors];
				NSMutableString *secondary = [NSMutableString string];
				if ( numErrors > 3 )
				{
					[secondary appendString:NSLocalizedString(@"The first 3 are:\n", @"To be followed by 3 error messages")];
				}
				
				NSUInteger i;
				for ( i = 0; i < ((numErrors > 3) ? 3 : numErrors); i++ )
				{
					[secondary appendFormat:@"%@\n", detailedErrors[i].localizedDescription];
				}
				
				NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionaryWithDictionary:inError.userInfo];
				userInfo[NSLocalizedDescriptionKey] = errorString;
				userInfo[NSLocalizedRecoverySuggestionErrorKey]  = secondary;
                
				result = [NSError errorWithDomain:inError.domain code:inError.code userInfo:userInfo];
			}
		}
	}
    
	// for errors we didn't customize, call super, passing the original error
	if ( !result )
	{
		result = [super willPresentError:inError];
	}
    
    return result;
}

@end

/* Note JK20180125

 I've removed the above assertion because it tripped for me when I had
 enabled asynchronous saving, and I think it is a false alarm.  The call
 stack was as shown below.  Indeed it was on a secondary thread, because
 the main thread invoked
 -[BkmxDoc writeSafelyToURL:ofType:forSaveOperation:error:], which the
 system called on a secondary thread.  Is that not the whole idea of
 asynchronous saving?  For macOS 10.7+, this class does return YES for
 -canAsynchronouslyWriteToURL:::.

 Thread 50 Queue : com.apple.root.default-qos (concurrent)
 #0    0x00007fff57c3823f in -[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:] ()
 #1    0x00000001002b7e13 in -[BSManagedDocument contentsForURL:ofType:saveOperation:error:] at /Users/jk/Documents/Programming/Projects/BSManagedDocument/BSManagedDocument.m:396
 #2    0x00000001002b9881 in -[BSManagedDocument writeToURL:ofType:forSaveOperation:originalContentsURL:error:] at /Users/jk/Documents/Programming/Projects/BSManagedDocument/BSManagedDocument.m:872
 #3    0x00000001002b95da in -[BSManagedDocument writeSafelyToURL:ofType:forSaveOperation:error:] at /Users/jk/Documents/Programming/Projects/BSManagedDocument/BSManagedDocument.m:791
 #4    0x00000001002e0d41 in -[BkmxDoc writeSafelyToURL:ofType:forSaveOperation:error:] at /Users/jk/Documents/Programming/Projects/BkmkMgrs/BkmxDoc.m:5383
 #5    0x00007fff53c39294 in __85-[NSDocument(NSDocumentSaving) _saveToURL:ofType:forSaveOperation:completionHandler:]_block_invoke_2.1146 ()
 #6    0x0000000100887c3d in _dispatch_call_block_and_release ()
 #7    0x000000010087fd1f in _dispatch_client_callout ()
 #8    0x000000010088dba8 in _dispatch_queue_override_invoke ()
 #9    0x0000000100881b76 in _dispatch_root_queue_drain ()
 #10    0x000000010088184f in _dispatch_worker_thread3 ()
 #11    0x00000001008fc1c2 in _pthread_wqthread ()
 #12    0x00000001008fbc45 in start_wqthread ()
 Enqueued from com.apple.main-thread (Thread 1) Queue : com.apple.main-thread (serial)
 #0    0x0000000100896669 in _dispatch_root_queue_push_override ()
 #1    0x00007fff53c3916f in __85-[NSDocument(NSDocumentSaving) _saveToURL:ofType:forSaveOperation:completionHandler:]_block_invoke.1143 ()
 #2    0x00007fff535b2918 in __68-[NSDocument _errorForOverwrittenFileWithSandboxExtension:andSaver:]_block_invoke_2.1097 ()
 #3    0x00007fff57de36c1 in __110-[NSFileCoordinator(NSPrivate) _coordinateReadingItemAtURL:options:writingItemAtURL:options:error:byAccessor:]_block_invoke.448 ()
 #4    0x00007fff57de2657 in -[NSFileCoordinator(NSPrivate) _withAccessArbiter:invokeAccessor:orDont:andRelinquishAccessClaim:] ()
 #5    0x00007fff57de32cb in -[NSFileCoordinator(NSPrivate) _coordinateReadingItemAtURL:options:writingItemAtURL:options:error:byAccessor:] ()
 #6    0x00007fff53c34954 in -[NSDocument(NSDocumentSaving) _fileCoordinator:coordinateReadingContentsAndWritingItemAtURL:byAccessor:] ()
 #7    0x00007fff53c34b62 in -[NSDocument(NSDocumentSaving) _coordinateReadingContentsAndWritingItemAtURL:byAccessor:] ()
 #8    0x00007fff535b2860 in __68-[NSDocument _errorForOverwrittenFileWithSandboxExtension:andSaver:]_block_invoke.1096 ()
 #9    0x00007fff53674eb4 in -[NSDocument(NSDocumentSerializationAPIs) continueFileAccessUsingBlock:] ()
 #10    0x00007fff5367688a in __62-[NSDocument(NSDocumentSerializationAPIs) _performFileAccess:]_block_invoke.354 ()
 #11    0x00007fff535f38c0 in __62-[NSDocumentController(NSInternal) _onMainThreadInvokeWorker:]_block_invoke.2153 ()
 #12    0x00007fff55acc58c in __CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__ ()
 #13    0x00007fff55aaf043 in __CFRunLoopDoBlocks ()
 #14    0x00007fff55aae6ce in __CFRunLoopRun ()
 #15    0x00007fff55aadf43 in CFRunLoopRunSpecific ()
 #16    0x00007fff54dc5e26 in RunCurrentEventLoopInMode ()
 #17    0x00007fff54dc5b96 in ReceiveNextEventCommon ()
 #18    0x00007fff54dc5914 in _BlockUntilNextEventMatchingListInModeWithFilter ()
 #19    0x00007fff53090f5f in _DPSNextEvent ()
 #20    0x00007fff53826b4c in -[NSApplication(NSEvent) _nextEventMatchingEventMask:untilDate:inMode:dequeue:] ()
 #21    0x00007fff53085d6d in -[NSApplication run] ()
 #22    0x00007fff53054f1a in NSApplicationMain ()
 #23    0x00000001000014bc in main at /Users/jk/Documents/Programming/Projects/BkmkMgrs/Bkmx-Main.m:83
 #24    0x00007fff7d3c1115 in start ()
*/
