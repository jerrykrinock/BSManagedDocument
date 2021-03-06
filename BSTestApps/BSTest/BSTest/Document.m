//
//  Document.m
//  BSTest
//
//  Created by Abizer Nasir on 19/12/2012.
//  Copyright (c) 2012 Jungle Candy Software. All rights reserved.
//

#import "Document.h"
#import "WindowController.h"

@implementation Document

- (id)init {
    self = [super init];
    if (self) {
        // Add your subclass-specific initialization here.
    }
    return self;
}

- (void)makeWindowControllers {
    WindowController *windowController = [WindowController new];
    [self addWindowController:windowController];

#if !__has_feature(objc_arc)
    [windowController release];
#endif
}

- (void)windowControllerDidLoadNib:(NSWindowController *)aController {
    [super windowControllerDidLoadNib:aController];
    // Add any code here that needs to be executed once the windowController has loaded the document's window.
}

- (BOOL)configurePersistentStoreCoordinatorWithDescription:(NSPersistentStoreDescription *)description error:(NSError **)outError {
    description.shouldInferMappingModelAutomatically = YES;
    description.shouldMigrateStoreAutomatically = YES;
    return [super configurePersistentStoreCoordinatorWithDescription:description error:outError];
}

@end
