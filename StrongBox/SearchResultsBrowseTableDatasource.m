//
//  SearchResultsBrowseTableDatasource.m
//  Strongbox-iOS
//
//  Created by Mark on 24/04/2020.
//  Copyright © 2020 Mark McGuill. All rights reserved.
//

#import "SearchResultsBrowseTableDatasource.h"
#import "DatabaseSearchAndSorter.h"
#import "BrowseTableViewCellHelper.h"

@interface SearchResultsBrowseTableDatasource ()

@property (strong, nonatomic) NSArray<Node*> *searchResults;
@property Model* viewModel;
@property BrowseTableViewCellHelper* cellHelper;

@end

@implementation SearchResultsBrowseTableDatasource

- (instancetype)initWithModel:(Model*)model tableView:(nonnull UITableView *)tableView {
    self = [super init];
    if (self) {
        self.viewModel = model;
        self.cellHelper = [[BrowseTableViewCellHelper alloc] initWithModel:self.viewModel tableView:tableView];
    }
    return self;
}

- (BOOL)supportsSlideActions {
    return YES;
}

- (NSUInteger)sections {
    return 1;
}

- (nonnull UITableViewCell *)cellForRowAtIndexPath:(nonnull NSIndexPath *)indexPath {
    Node* node = [self getNodeFromIndexPath:indexPath];
    
    return [self.cellHelper getBrowseCellForNode:node indexPath:indexPath totp:NO showGroupLocation:YES];
}

- (NSUInteger)rowsForSection:(NSUInteger)section {
    return self.searchResults.count;
}

- (NSString*)titleForSection:(NSUInteger)section {
    return nil;
}

- (Node*)getNodeFromIndexPath:(NSIndexPath*)indexPath {
    NSArray<Node*>* dataSource = self.searchResults;
    
    if(!dataSource || indexPath.row >= dataSource.count) {
        NSLog(@"EEEEEK: WARNWARN - Should never happen but unknown node for indexpath: [%@]", indexPath);
        return nil;
    }
    
    return dataSource[indexPath.row];
}

- (void)updateSearchResults:(UISearchController*)searchController {
    DatabaseSearchAndSorter* searcher = [[DatabaseSearchAndSorter alloc] initWithModel:self.viewModel];

    self.searchResults = [searcher search:searchController.searchBar.text
                                    scope:(SearchScope)searchController.searchBar.selectedScopeButtonIndex
                              dereference:self.viewModel.metadata.searchDereferencedFields
                    includeKeePass1Backup:self.viewModel.metadata.showKeePass1BackupGroup
                        includeRecycleBin:self.viewModel.metadata.showRecycleBinInSearchResults
                           includeExpired:self.viewModel.metadata.showExpiredInSearch
                            includeGroups:YES];
}

@end
