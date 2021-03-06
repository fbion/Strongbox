//
//  FavIconDownloader.m
//  Strongbox
//
//  Created by Mark on 17/12/2019.
//  Copyright © 2019 Mark McGuill. All rights reserved.
//

#import "FavIconDownloader.h"
#import "PreferencesWindowController.h"
#import "NSArray+Extensions.h"
#import "FavIconManager.h"
#import "Settings.h"
#import "FavIconResultTableCellView.h"
#import "Utils.h"
#import "MacNodeIconHelper.h"
#import "Alerts.h"

@interface FavIconDownloader () <NSTableViewDataSource>

typedef NS_ENUM (NSInteger, FavIconBulkDownloadStatus) {
    kFavIconBulkStatusInitial,
    kFavIconBulkStatusPausing,
    kFavIconBulkStatusPaused,
    kFavIconBulkStatusInProgress,
    kFavIconBulkStatusDone,
};

@property (weak) IBOutlet NSButton *buttonIncludeItemsWithCustomIcons;
@property (weak) IBOutlet NSTextField *statusLabel;
@property (weak) IBOutlet NSButton *buttonPreferences;
@property (weak) IBOutlet NSButton *buttonViewResults;
@property (weak) IBOutlet NSButton *buttonRetry;
@property (weak) IBOutlet NSTextField *labelSuccesses;
@property (weak) IBOutlet NSTextField *errorCountLabel;
@property (weak) IBOutlet NSTextField *progressLabel;
@property (weak) IBOutlet NSProgressIndicator *progressView;
@property (weak) IBOutlet NSButton *imageViewStartStop;
@property (weak) IBOutlet NSTabView *tabView;
@property (weak) IBOutlet NSTableView *tableViewResults;
@property (weak) IBOutlet NSTableView *tableViewSelectPreferred;

@property NSArray<Node*> *nodes;
@property FavIconBulkDoneBlock onDone;
@property ViewModel* viewModel;

@property NSArray<Node*> *validNodes;
@property NSArray<NSURL*> *validUniqueUrls;

@property FavIconBulkDownloadStatus status;
@property NSMutableDictionary<NSURL*, NSArray<NSImage*>*>* results;
@property NSOperationQueue* queue;

@property NSMutableDictionary<NSUUID*, NSNumber*> *nodeSelected;
@property (weak) IBOutlet NSButton *buttonSetIcons;

@property Node* nodeToChoosePreferredIconsFor;

@end

@implementation FavIconDownloader

+ (instancetype)instantiate:(NSArray<Node *> *)nodes viewModel:(ViewModel *)viewModel onDone:(FavIconBulkDoneBlock)onDone {
    NSStoryboard* sb = [NSStoryboard storyboardWithName:@"DownloadFavIcons" bundle:nil];
    FavIconDownloader* instance = [sb instantiateInitialController];
    
    instance.nodes = nodes;
    instance.onDone = onDone;
    instance.viewModel = viewModel;
    
    return instance;
}

+ (instancetype)showUi:(NSViewController *)parentVc nodes:(NSArray<Node *> *)nodes viewModel:(ViewModel *)viewModel onDone:(FavIconBulkDoneBlock)onDone {
    FavIconDownloader* instance = [FavIconDownloader instantiate:nodes viewModel:viewModel onDone:onDone];
  
    [parentVc presentViewControllerAsSheet:instance];
    
    return instance;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self.tableViewResults registerNib:[[NSNib alloc] initWithNibNamed:@"FavIconResultTableCell" bundle:nil] forIdentifier:@"FavIconResultTableCellIdentifier"];
    self.tableViewResults.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    
    self.tableViewSelectPreferred.action = @selector(onClickPreferredIcon:);
    
    [self.tabView setTabViewType:NSNoTabsLineBorder];
    self.imageViewStartStop.focusRingType = NSFocusRingTypeNone;

    [self loadAndValidateNodesAndUrls];
    
    self.queue = [NSOperationQueue new];
    self.queue.maxConcurrentOperationCount = 8;

    self.results = @{}.mutableCopy;
    self.nodeSelected = @{}.mutableCopy;
    
    [self bindUi];
  
    // Express kick off if only 1 item
    
    if(self.validUniqueUrls.count == 1) {
        [self onStartStop:nil];
    }
}

- (void)loadAndValidateNodesAndUrls {
    BOOL overwriteExisting = self.buttonIncludeItemsWithCustomIcons.state == NSOnState;
    
    self.validNodes = @[];
    self.validUniqueUrls = @[];

    self.validNodes = [[self.nodes filter:^BOOL(Node * _Nonnull obj) {
            return !obj.isGroup &&
            obj.fields.url.length != 0 &&
            [NSURL URLWithString:obj.fields.url] != nil &&
            (overwriteExisting || obj.isUsingKeePassDefaultIcon);
        }] sortedArrayUsingComparator:finderStyleNodeComparator];

    NSMutableSet<NSURL*> *added = [NSMutableSet setWithCapacity:self.nodes.count];
    NSMutableArray<NSURL*> *addedArray = [NSMutableArray arrayWithCapacity:self.nodes.count];
    
    for (Node* node in self.validNodes) {
        NSURL* url = [NSURL URLWithString:node.fields.url];
        if(![added containsObject:url]) {
            [added addObject:url];
            [addedArray addObject:url];
        }
    }
    
    self.validUniqueUrls = addedArray.copy;
}

- (IBAction)onPreferences:(id)sender {
    [PreferencesWindowController.sharedInstance showFavIconPreferences];
}

- (void)bindUi {
    self.statusLabel.stringValue = [self getStatusString];

    self.buttonIncludeItemsWithCustomIcons.enabled =
    self.buttonPreferences.enabled =(
        self.status != kFavIconBulkStatusInProgress &&
        self.status != kFavIconBulkStatusPausing);

    self.buttonViewResults.hidden = self.buttonRetry.hidden =
        self.results.count == 0 ||
        self.validUniqueUrls.count == 0 ||
        self.status == kFavIconBulkStatusInProgress ||
        self.status == kFavIconBulkStatusPausing;

    NSUInteger errored = [self.results.allValues filter:^BOOL(NSArray<NSImage *> * _Nonnull obj) {
        return obj.count == 0;
    }].count;

    self.labelSuccesses.stringValue = self.validUniqueUrls.count == 0 ? @"" : @(self.results.count - errored).stringValue;
    self.errorCountLabel.stringValue = self.validUniqueUrls.count == 0 ? @"" : @(errored).stringValue;

    self.progressLabel.stringValue = [NSString stringWithFormat:@"%lu/%lu", (unsigned long)self.results.count, (unsigned long)self.validUniqueUrls.count];
    self.progressLabel.hidden = self.validUniqueUrls.count == 0;

    self.progressView.doubleValue = self.validUniqueUrls.count == 0 ? 0 : (((float)self.results.count / (float)self.validUniqueUrls.count) * 100);

    BOOL featureAvailable = Settings.sharedInstance.fullVersion || Settings.sharedInstance.freeTrial;
    
    if(!featureAvailable) {
        NSString* loc = NSLocalizedString(@"mac_button_set_favicons_pro_only", @"Set Icons (Pro Only)");
        [self.buttonSetIcons setTitle:loc];
    }
    
    self.buttonSetIcons.enabled = self.nodeSelected.count > 0 && featureAvailable;
    
    [self bindStartStopStatusImage:errored];
}

- (void)bindStartStopStatusImage:(NSUInteger)errored {
    if(self.validUniqueUrls.count == 0) {
        [self.imageViewStartStop setImage:[NSImage imageNamed:@"cancel"]];
        if (@available(macOS 10.14, *)) {
            [self.imageViewStartStop setContentTintColor:NSColor.redColor];
        }
        self.imageViewStartStop.enabled = NO;
        return;
    }
    
    if(self.status == kFavIconBulkStatusInitial ||
       self.status == kFavIconBulkStatusPaused) {
        [self.imageViewStartStop setImage:[NSImage imageNamed:@"Play"]];
        self.imageViewStartStop.enabled = self.validUniqueUrls.count > 0;
    }
    else if(self.status == kFavIconBulkStatusInProgress) {
        [self.imageViewStartStop setImage:[NSImage imageNamed:@"Pause"]];
        if (@available(macOS 10.14, *)) {
            [self.imageViewStartStop setContentTintColor:nil];
        }
        self.imageViewStartStop.enabled = YES;
    }
    else if(self.status == kFavIconBulkStatusPausing) {
        if (@available(macOS 10.14, *)) {
            [self.imageViewStartStop setContentTintColor:NSColor.systemGrayColor];
        }
        self.imageViewStartStop.enabled = NO;
    }
    else if(self.status == kFavIconBulkStatusDone) {
        if(errored == 0) {
            [self.imageViewStartStop setImage:[NSImage imageNamed:@"ok"]];
            if (@available(macOS 10.14, *)) {
                [self.imageViewStartStop setContentTintColor:NSColor.systemGreenColor];
            }
        }
        else if (errored == self.validUniqueUrls.count) {
            [self.imageViewStartStop setImage:[NSImage imageNamed:@"cancel"]];
            if (@available(macOS 10.14, *)) {
                [self.imageViewStartStop setContentTintColor:NSColor.redColor];
            }
        }
        else {
            [self.imageViewStartStop setImage:[NSImage imageNamed:@"ok"]];
            if (@available(macOS 10.14, *)) {
                [self.imageViewStartStop setContentTintColor:NSColor.systemYellowColor];
            }
        }
    }
}

- (NSString*)getStatusString {
    if(self.validUniqueUrls.count == 0) {
        return NSLocalizedString(@"favicon_status_no_eligible_items", @"No eligible items with valid URLs found...");
    }
    
    switch(self.status) {
        case kFavIconBulkStatusInitial:
            return NSLocalizedString(@"favicon_status_initial", @"Tap Play to start search");
        case kFavIconBulkStatusInProgress:
            return NSLocalizedString(@"favicon_status_in_progress", @"Searching...");
        case kFavIconBulkStatusPausing:
            return NSLocalizedString(@"favicon_status_pausing", @"Pausing (may take a few seconds)...");
        case kFavIconBulkStatusPaused:
            return NSLocalizedString(@"favicon_status_paused", @"FavIcon search paused. Tap Play to Continue...");
        case kFavIconBulkStatusDone:
            return NSLocalizedString(@"favicon_status_done", @"Search Complete. Tap View Results to see FavIcons");
        default:
            return @"<Unknown>";
    }
}

- (IBAction)onBackToSearch:(id)sender {
    [self.tabView selectTabViewItemAtIndex:0];
}

- (IBAction)onStartStop:(id)sender {
    if(self.status == kFavIconBulkStatusInitial && self.validUniqueUrls.count > 0) {
        [self startOrResume];
    }
    else if (self.status == kFavIconBulkStatusInProgress) {
        [self pause];
    }
    else if (self.status == kFavIconBulkStatusPaused) {
        [self startOrResume];
    }
}

- (void)startOrResume {
    self.status = kFavIconBulkStatusInProgress;

    self.queue.suspended = YES;

    NSMutableArray<NSURL*>* foo = self.validUniqueUrls.mutableCopy;

    for (NSURL* done in self.results) {
        [foo removeObject:done];
    }

    [FavIconManager.sharedInstance getFavIconsForUrls:foo
                                                queue:self.queue
                                              options:Settings.sharedInstance.favIconDownloadOptions
                                         withProgress:^(NSURL * _Nonnull url, NSArray<IMAGE_TYPE_PTR> * _Nonnull images) {
        [self onProgressUpdate:url images:images];
    }];

    self.queue.suspended = NO;

    [self bindUi];
}

- (void)pause {
    // Pause is actually a full on cancel... Resume/Start just finds items that we don't have results for and queues them up
    [self.queue cancelAllOperations];

    self.status = kFavIconBulkStatusPausing;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0L), ^{
        [self.queue waitUntilAllOperationsAreFinished];
        self.status = kFavIconBulkStatusPaused;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self bindUi];
        });
    });

    [self bindUi];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Table View Data Source

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return tableView == self.tableViewResults ? self.validNodes.count : (self.nodeToChoosePreferredIconsFor ? [self getImagesForNode:self.nodeToChoosePreferredIconsFor].count : 0);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if(tableView == self.tableViewResults) {
        return [self viewForFavIconResults:row];
    }
    else {
        return [self viewForSelectingPreferredFavIcon:row];
    }
}

- (NSView*)viewForFavIconResults:(NSInteger)row {
    FavIconResultTableCellView* cell = (FavIconResultTableCellView*)[self.tableViewResults makeViewWithIdentifier:@"FavIconResultTableCellIdentifier" owner:nil];
    
    Node* node = self.validNodes[row];
    
    cell.title.stringValue = node.title;
    
    NSNumber* selectedIndex = self.nodeSelected[node.uuid];
//    NSLog(@"cell: %@ => %@", node.title, selectedIndex.stringValue);
    
    NSArray<IMAGE_TYPE_PTR> *images = [self getImagesForNode:node];
    IMAGE_TYPE_PTR selectedImage = selectedIndex != nil ? images[selectedIndex.intValue] : nil;
    
    cell.checked = selectedImage != nil;
    cell.checkable = images.count > 0;
    
    if (images.count > 0) {
        // Choose Alternate icon
        
        cell.showIconChooseButton = images.count > 1;
        
        cell.onClickChooseIcon = ^{
            self.nodeToChoosePreferredIconsFor = node;
            [self refreshAndShowPreferredIconChooserTab];
        };

        // Check Changed...

        __weak FavIconResultTableCellView* weakCell = cell;
        cell.onCheckChanged = ^{
             if(!weakCell.checked) {
                 [self.nodeSelected removeObjectForKey:node.uuid];
             }
             else {
                 IMAGE_TYPE_PTR best = [FavIconManager.sharedInstance selectBest:images];
                 self.nodeSelected[node.uuid] = @([images indexOfObject:best]);
             }
             
            [self bindUi];
            [self.tableViewResults reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                              columnIndexes:[NSIndexSet indexSetWithIndex:0]];
        };

        cell.subTitle.textColor = nil;
        
        if(selectedImage) {
            cell.subTitle.stringValue = [NSString stringWithFormat:NSLocalizedString(@"favicon_results_n_icons_found_with_xy_resolution_fmt", @"%lu Icons Found (%dx%d selected)"),
                                         (unsigned long)images.count,
                                         (int)selectedImage.size.width,
                                         (int)selectedImage.size.height];

            if(selectedImage.size.height != 32 || selectedImage.size.width != 32) {
                selectedImage = scaleImage(selectedImage, CGSizeMake(32, 32));
            }

            cell.icon.image = selectedImage;
            cell.icon.hidden = NO;
        }
        else {
            cell.subTitle.stringValue = [NSString stringWithFormat:NSLocalizedString(@"favicon_results_n_icons_found_none_selected_fmt", @"%lu Icons Found (None selected)"), (unsigned long)images.count];
            
            cell.icon.hidden = NO;
            cell.icon.image = [NSImage imageNamed:@"cancel"];
        }
    }
    else {
        cell.subTitle.stringValue = NSLocalizedString(@"favicon_results_no_icons_found", @"No FavIcons Found");
        cell.subTitle.textColor = NSColor.redColor;
        
        cell.showIconChooseButton = NO;
        cell.onClickChooseIcon = nil;
        cell.icon.image = [NSImage imageNamed:@"error"];
        cell.onCheckChanged = nil;
    }

    return cell;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)onProgressUpdate:(NSURL*)url images:(NSArray<NSImage *>* _Nonnull)images {
    self.results[url] = images;
    
    // Auto Select Best Image for any nodes with this URL
    
    if(images.count) {
        for (Node* node in self.validNodes) {
            if([node.fields.url isEqualToString:url.absoluteString]) {
                NSArray<IMAGE_TYPE_PTR>* sorted = [self getImagesForNode:node];
                IMAGE_TYPE_PTR best = [FavIconManager.sharedInstance selectBest:sorted];
                NSUInteger bestIndex = [sorted indexOfObject:best];
                self.nodeSelected[node.uuid] = @(bestIndex);
            }
        }
    }
    
    // Done?
    
    if(self.results.count == self.validUniqueUrls.count) {
        self.status = kFavIconBulkStatusDone;
    }
    
    // Update UI....
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self bindUi];
        
        if(self.status == kFavIconBulkStatusDone) {
            NSUInteger errored = [self.results.allValues filter:^BOOL(NSArray<NSImage *> * _Nonnull obj) {
                return obj.count == 0;
            }].count;
            
            if (errored == 0) { // Auto Segue if everything was successful
                [self refreshAndDisplaySearchResults];
            }
        }
    });
}

- (IBAction)onViewResults:(id)sender {
    [self refreshAndDisplaySearchResults];
}

- (NSArray<IMAGE_TYPE_PTR>*)getImagesForNode:(Node*)node {
    NSArray<IMAGE_TYPE_PTR>* images = self.results[[NSURL URLWithString:node.fields.url]];

    NSArray<IMAGE_TYPE_PTR>* sorted = [images sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        IMAGE_TYPE_PTR i1 = (IMAGE_TYPE_PTR)obj1;
        IMAGE_TYPE_PTR i2 = (IMAGE_TYPE_PTR)obj2;

        if(i1.size.width < i2.size.width) {
            return NSOrderedAscending;
        }
        else if (i1.size.width > i2.size.width) {
            return NSOrderedDescending;
        }
        
        return NSOrderedSame;
    }];
    
    return sorted;
}

- (void)refreshAndDisplaySearchResults {
    self.validNodes = [self.validNodes sortedArrayUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        Node* node1 = (Node*)obj1;
        Node* node2 = (Node*)obj2;
    
        NSArray<IMAGE_TYPE_PTR> *images1 = [self getImagesForNode:node1];
        NSArray<IMAGE_TYPE_PTR> *images2 = [self getImagesForNode:node2];
        
        return images1.count > 0 && images2.count > 0 ? finderStringCompare(node1.title, node2.title) : images1.count == 0 ? NSOrderedDescending : NSOrderedAscending;
    }];
    
    [self.tableViewResults reloadData];
    [self.tabView selectTabViewItemAtIndex:1];
}

//////

- (void)refreshAndShowPreferredIconChooserTab {
    [self.tableViewSelectPreferred reloadData];
    
    NSNumber* currentlySelected = self.nodeSelected[self.nodeToChoosePreferredIconsFor.uuid];
    
    NSLog(@"refresh: %@ => %@", self.nodeToChoosePreferredIconsFor.title, currentlySelected.stringValue);
      
    if(currentlySelected) {
        NSArray<IMAGE_TYPE_PTR>* images = [self getImagesForNode:self.nodeToChoosePreferredIconsFor];
        IMAGE_TYPE_PTR currentlySelectedImage = images[currentlySelected.intValue];
        NSUInteger row = [images indexOfObject:currentlySelectedImage];
        [self.tableViewSelectPreferred selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
    
    [self.tabView selectTabViewItemAtIndex:2];
}

- (NSView*)viewForSelectingPreferredFavIcon:(NSInteger)row {
    FavIconResultTableCellView* cell = (FavIconResultTableCellView*)[self.tableViewResults makeViewWithIdentifier:@"FavIconResultTableCellIdentifier" owner:nil];

    NSArray<IMAGE_TYPE_PTR>* images = [self getImagesForNode:self.nodeToChoosePreferredIconsFor];
    IMAGE_TYPE_PTR image = images[row];
    
    cell.title.stringValue = self.nodeToChoosePreferredIconsFor.title;
    cell.subTitle.stringValue = [NSString stringWithFormat:@"%dx%d", (int)image.size.width, (int)image.size.height];
    
    if(image.size.height != 32 || image.size.width != 32) {
        image = scaleImage(image, CGSizeMake(32, 32));
    }
    
    cell.icon.image = image;
    
    return cell;
}

- (void)onClickPreferredIcon:(id)sender {
    NSUInteger selectedIndex = self.tableViewSelectPreferred.selectedRow;

    if(selectedIndex != -1) {
        self.nodeSelected[self.nodeToChoosePreferredIconsFor.uuid] = @(selectedIndex);
    }

    NSUInteger row = [self.validNodes indexOfObject:self.nodeToChoosePreferredIconsFor];
    [self.tableViewResults reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:0]];

    [self.tabView selectTabViewItemAtIndex:1];
}

- (IBAction)onRetry:(id)sender {
    NSArray<NSURL*>* errored = [self.results.allKeys filter:^BOOL(NSURL * _Nonnull obj) {
        return self.results[obj].count == 0;
    }];

    if(errored.count == 0) {
        [Alerts yesNo:NSLocalizedString(@"favicon_clear_all_and_retry_message", @"Are you sure you want to clear current results and retry all items?")
               window:self.view.window
           completion:^(BOOL yesNo) {
            if(yesNo) {
                [self retryAll];
            }
        }];
    }
    else {
        [Alerts twoOptionsWithCancel:NSLocalizedString(@"favicon_retry_all_or_failed_title", @"Retry All or Failed?")
                     informativeText:NSLocalizedString(@"favicon_retry_all_or_failed_message", @"Would you like to retry all items, or just the failed ones?")
                   option1AndDefault:NSLocalizedString(@"favicon_retry_failed_action", @"Retry Failed")
                             option2:NSLocalizedString(@"favicon_retry_all_action", @"Retry All")
                              window:self.view.window
                          completion:^(NSUInteger zeroForCancel) {
            if(zeroForCancel == 1) {
                [self retryFailed];
            }
            else if (zeroForCancel == 2) {
                [self retryAll];
            }
        }];
    }
}

- (void)retryAll {
    [self.results removeAllObjects];
    
    [self bindUi];
    
    [self startOrResume];
}

- (void)retryFailed {
    NSArray<NSURL*>* errored = [self.results.allKeys filter:^BOOL(NSURL * _Nonnull obj) {
        return self.results[obj].count == 0;
    }];

    [self.results removeObjectsForKeys:errored];
    
    [self bindUi];
    
    [self startOrResume];
}

- (IBAction)onIncludeItemsWithCustomIcons:(id)sender {
    [self loadAndValidateNodesAndUrls];
    [self bindUi];
}

- (IBAction)onCancel:(id)sender {
    [self.queue cancelAllOperations];
    self.queue = nil;
    
    [self.presentingViewController dismissViewController:self];
    
    if (self.onDone) {
        self.onDone(NO, nil);
    }
}

- (IBAction)onSetIcons:(id)sender {
    NSMutableDictionary<NSUUID*, IMAGE_TYPE_PTR> *selected = @{}.mutableCopy;

    for (Node* obj in self.validNodes) {
        NSNumber* index = self.nodeSelected[obj.uuid];
        if(index != nil) {
            NSArray<IMAGE_TYPE_PTR>* images = [self getImagesForNode:obj];
            selected[obj.uuid] = images[index.intValue];
        }
    }

    // Confirm Alert? X icons will be changed?
    
    if(selected.count > 1) {
        NSString* loc = NSLocalizedString(@"set_favicons_are_you_sure_yes_no_fmt", @"This will set the icons for %d items to your selected FavIcons. Are you sure you want to continue?");
        
        NSString *info = [NSString stringWithFormat:loc, selected.count];
        [Alerts yesNo:NSLocalizedString(@"generic_are_you_sure", @"Are you sure?")
      informativeText:info
               window:self.view.window
           completion:^(BOOL yesNo) {
            if(yesNo) {
                if (self.onDone) {
                    [self.queue cancelAllOperations];
                    self.queue = nil;

                    [self.presentingViewController dismissViewController:self];
                    
                    self.onDone(YES, selected);
                }
            }
        }];
    }
    else {
        if (self.onDone) {
            [self.queue cancelAllOperations];
            self.queue = nil;

            [self.presentingViewController dismissViewController:self];
            
            self.onDone(YES, selected);
        }
    }
}

@end
