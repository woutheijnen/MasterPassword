//==============================================================================
// This file is part of Master Password.
// Copyright (c) 2011-2017, Maarten Billemont.
//
// Master Password is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Master Password is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You can find a copy of the GNU General Public License in the
// LICENSE file.  Alternatively, see <http://www.gnu.org/licenses/>.
//==============================================================================

MP_LIBS_BEGIN
#import <StoreKit/StoreKit.h>
MP_LIBS_END

#import "MPSitesViewController.h"
#import "MPiOSAppDelegate.h"
#import "MPAppDelegate_Store.h"
#import "MPPopdownSegue.h"
#import "MPAppDelegate_Key.h"
#import "MPSiteCell.h"
#import "MPAnswersViewController.h"
#import "MPMessageViewController.h"

static const NSString *MPTransientPasswordItem = @"MPTransientPasswordItem";

typedef NS_OPTIONS( NSUInteger, MPPasswordsTips ) {
    MPPasswordsBadNameTip = 1 << 0,
};

@interface MPSitesViewController()<NSFetchedResultsControllerDelegate>

@property(nonatomic, strong) NSFetchedResultsController *fetchedResultsController;
@property(nonatomic, strong) NSArray *queryGroups;
@property(nonatomic, strong) NSCharacterSet *siteNameAcceptableCharactersSet;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *dataSource;
@property(nonatomic, weak) UIViewController *popdownVC;

@end

@implementation MPSitesViewController

#pragma mark - Life

- (void)viewDidLoad {

    [super viewDidLoad];

    NSMutableCharacterSet *siteNameAcceptableCharactersSet = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [siteNameAcceptableCharactersSet formIntersectionWithCharacterSet:[[NSCharacterSet uppercaseLetterCharacterSet] invertedSet]];
    [siteNameAcceptableCharactersSet addCharactersInString:@"@.-+~&_;:/"];
    self.siteNameAcceptableCharactersSet = siteNameAcceptableCharactersSet;

    self.dataSource = [NSMutableArray new];

    self.view.backgroundColor = [UIColor clearColor];
    if (@available( iOS 11, * ))
        self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.collectionView automaticallyAdjustInsetsForKeyboard];
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.keyboardAppearance = UIKeyboardAppearanceDark;
}

- (void)viewWillAppear:(BOOL)animated {

    [super viewWillAppear:animated];

    [self registerObservers];
    [self updateConfigKey:nil];
    [self updateSpectreAlerts];

    static NSRegularExpression *bareHostRE = nil;
    static dispatch_once_t once = 0;
    dispatch_once( &once, ^{
        bareHostRE = [NSRegularExpression regularExpressionWithPattern:@"([^\\.]+\\.[^\\.]+)$" options:0 error:nil];
    } );

    NSURL *pasteboardURL = nil;
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    if (@available(iOS 10.0, *))
        pasteboardURL = pasteboard.hasURLs? pasteboard.URL: nil;
    else
        pasteboardURL = [NSURL URLWithString:pasteboard.string];

    if (pasteboardURL.host)
        self.query = NSNullToNil( [[pasteboardURL.host firstMatchGroupsOfExpression:bareHostRE] firstObject] );
    else
        [self reloadSites];
}

- (void)viewDidAppear:(BOOL)animated {

    [super viewDidAppear:animated];

    [MPiOSAppDelegate managedObjectContextPerformBlock:^(NSManagedObjectContext *context) {
        MPUserEntity *activeUser = [[MPiOSAppDelegate get] activeUserInContext:context];
        if (![MPAlgorithmDefault tryMigrateUser:activeUser inContext:context])
            PearlMainQueue( ^{
                [self performSegueWithIdentifier:@"message" sender:
                        [MPMessage messageWithTitle:@"You have sites that can be upgraded." text:
                                        @"Upgrading a site allows it to take advantage of the latest improvements in the Master Password algorithm.\n\n"
                                                "When you upgrade a site, a new and stronger password will be generated for it.  To upgrade a site, first log into the site, navigate to your account preferences where you can change the site's password.  Make sure you fill in any \"current password\" fields on the website first, then press the upgrade button here to get your new site password.\n\n"
                                                "You can then update your site's account with the new and stronger password.\n\n"
                                                "The upgrade button can be found in the site's settings and looks like this:"
                                               info:YES]];
            } );
        [context saveToStore];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {

    [super viewWillDisappear:animated];

    PearlRemoveNotificationObservers();
}

- (void)viewDidLayoutSubviews {

    [super viewDidLayoutSubviews];

    if (@available( iOS 11, * )) {
        self.collectionView.layoutMargins =
                UIEdgeInsetsMake( [self.collectionView occludedInsets].top - self.view.safeAreaInsets.top, 0, 0, 0 );
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {

    if ([segue.identifier isEqualToString:@"popdown"])
        self.popdownVC = segue.destinationViewController;
    if ([segue.identifier isEqualToString:@"answers"])
        ((MPAnswersViewController *)segue.destinationViewController).site =
                [[MPSiteCell findAsSuperviewOf:sender] siteInContext:[MPiOSAppDelegate managedObjectContextForMainThreadIfReady]];
    if ([segue.identifier isEqualToString:@"message"])
        ((MPMessageViewController *)segue.destinationViewController).message = sender;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {

    [self.collectionView.collectionViewLayout invalidateLayout];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {

    return [self.dataSource count];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {

    return [self.dataSource[(NSUInteger)section] count];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {

    MPSiteCell *cell = [MPSiteCell dequeueFromCollectionView:collectionView indexPath:indexPath];
    [cell setQueryGroups:self.queryGroups];
    id item = self.dataSource[(NSUInteger)indexPath.section][(NSUInteger)indexPath.item];
    if ([item isKindOfClass:[MPSiteEntity class]])
        [cell setSite:item animated:NO];
    else // item == MPTransientPasswordItem
        [cell setTransientSite:self.query animated:NO];

    return cell;
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)collectionViewLayout;
    CGFloat availableWidth = collectionView.bounds.size.width
                             - collectionView.layoutMargins.left - collectionView.layoutMargins.right
                             - layout.sectionInset.left - layout.sectionInset.right;
    CGFloat cells = MAX( 1, (int)((availableWidth + layout.minimumInteritemSpacing) / (318 + layout.minimumInteritemSpacing)) );
    return CGSizeMake( (availableWidth - layout.minimumInteritemSpacing * (cells - 1)) / cells, 100 );
}

#pragma mark - UIScrollDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {

    if (scrollView == self.collectionView)
        for (MPSiteCell *cell in [self.collectionView visibleCells])
            [cell setMode:MPPasswordCellModePassword animated:YES];
}

#pragma mark - NSFetchedResultsControllerDelegate

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {

    if (controller == self.fetchedResultsController)
        [self updateSites];
}

#pragma mark - UISearchBarDelegate

- (BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar {

    if (searchBar == self.searchBar) {
        searchBar.text = nil;
        return YES;
    }

    return NO;
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {

    if (searchBar == self.searchBar) {
        [self.searchBar setShowsCancelButton:YES animated:YES];
        [UIView animateWithDuration:0.3f animations:^{
            self.collectionView.backgroundColor = [self.collectionView.backgroundColor colorWithAlphaComponent:0.6f];
        }];
    }
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {

    if (searchBar == self.searchBar) {
        [self.searchBar setShowsCancelButton:NO animated:YES];
        [self reloadSites];

        [UIView animateWithDuration:0.3f animations:^{
            self.collectionView.backgroundColor = [self.collectionView.backgroundColor colorWithAlphaComponent:0];
        }];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {

    searchBar.text = nil;
    [searchBar resignFirstResponder];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {

    [searchBar resignFirstResponder];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {

    if (searchBar == self.searchBar) {
        if ([[self.query stringByTrimmingCharactersInSet:self.siteNameAcceptableCharactersSet] length])
            [self showTips:MPPasswordsBadNameTip];

        [self reloadSites];
    }
}

#pragma mark - Private

- (void)showTips:(MPPasswordsTips)showTips {

    [UIView animateWithDuration:0.3f animations:^{
        if (showTips & MPPasswordsBadNameTip)
            self.badNameTipContainer.visible = YES;
    }                completion:^(BOOL finished) {
        PearlMainQueueAfter( 5, ^{
            [UIView animateWithDuration:0.3f animations:^{
                if (showTips & MPPasswordsBadNameTip)
                    self.badNameTipContainer.visible = NO;
            }];
        } );
    }];
}

- (NSMutableArray<NSMutableArray *> *)createDataSource {

    NSString *query = self.query;
    BOOL needTransientItem = [query length] > 0;

    NSArray<id<NSFetchedResultsSectionInfo>> *sectionInfos = [self.fetchedResultsController sections];
    NSMutableArray *sections = [[NSMutableArray alloc] initWithCapacity:[sectionInfos count]];
    for (id<NSFetchedResultsSectionInfo> sectionInfo in sectionInfos) {
        NSArray<MPSiteEntity *> *sites = [sectionInfo.objects copy];
        [sections addObject:sites];

        if (needTransientItem)
            for (MPSiteEntity *site in sites)
                if ([site.name isEqualToString:query]) {
                    needTransientItem = NO;
                    break;
                }
    }

    if (needTransientItem)
        [sections addObject:@[ MPTransientPasswordItem ]];

    return sections;
}

- (void)registerObservers {

    PearlRemoveNotificationObservers();
    PearlAddNotificationObserver( UIApplicationWillResignActiveNotification, nil, [NSOperationQueue mainQueue],
            ^(MPSitesViewController *self, NSNotification *note) {
                [self.view endEditing:YES];
                self.view.visible = NO;
            } );
    PearlAddNotificationObserver( UIApplicationDidBecomeActiveNotification, nil, [NSOperationQueue mainQueue],
            ^(MPSitesViewController *self, NSNotification *note) {
                [UIView animateWithDuration:0.7f animations:^{
                    self.view.visible = YES;
                }];
            } );
    PearlAddNotificationObserver( UIApplicationWillEnterForegroundNotification, nil, [NSOperationQueue mainQueue],
            ^(MPSitesViewController *self, NSNotification *note) {
                [self viewWillAppear:YES];
                [self updateSpectreAlerts];
            } );
    PearlAddNotificationObserver( MPSignedOutNotification, nil, nil,
            ^(MPSitesViewController *self, NSNotification *note) {
                PearlMainQueue( ^{
                    self.fetchedResultsController = nil;
                    self.query = nil;
                } );
            } );
    PearlAddNotificationObserver( MPCheckConfigNotification, nil, nil,
            ^(MPSitesViewController *self, NSNotification *note) {
                PearlMainQueue( ^{
                    [self updateConfigKey:note.object];
                } );
            } );
    PearlAddNotificationObserver( NSPersistentStoreCoordinatorStoresWillChangeNotification, nil, nil,
            ^(MPSitesViewController *self, NSNotification *note) {
                self.fetchedResultsController = nil;
                [self reloadSites];
            } );
    PearlAddNotificationObserver( NSPersistentStoreCoordinatorStoresDidChangeNotification, nil, nil,
            ^(MPSitesViewController *self, NSNotification *note) {
                PearlMainQueue( ^{
                    [self reloadSites];
                    [self registerObservers];
                } );
            } );

    [[MPiOSAppDelegate get] managedObjectContextChanged:^(NSDictionary<NSManagedObjectID *, NSString *> *affectedObjects) {
        [MPiOSAppDelegate managedObjectContextForMainThreadPerformBlock:^(NSManagedObjectContext *mainContext) {
            // TODO: either move this into the app delegate or remove the duplicate signOutAnimated: call from the app delegate.
            if (![[MPiOSAppDelegate get] activeUserInContext:mainContext])
                [[MPiOSAppDelegate get] signOut];
        }];
    }];
}

- (void)updateConfigKey:(NSString *)key {

    if (!key || [key isEqualToString:NSStringFromSelector( @selector( dictationSearch ) )])
        self.searchBar.keyboardType = [[MPiOSConfig get].dictationSearch boolValue]? UIKeyboardTypeDefault: UIKeyboardTypeURL;
    if (!key || [key isEqualToString:NSStringFromSelector( @selector( hidePasswords ) )])
        [self.collectionView reloadData];
}

- (void)reloadSites {

    [self.fetchedResultsController.managedObjectContext performBlock:^{
        NSString *queryString = self.query;
        NSMutableArray *queryGroups = [NSMutableArray new];
        NSMutableString *queryPattern = [NSMutableString new];
        [queryString enumerateSubstringsInRange: NSMakeRange(0, [queryString length]) options: NSStringEnumerationByComposedCharacterSequences
                              usingBlock: ^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
            if (substringRange.location < 20) {
                [queryGroups addObject:substring];
                [queryPattern appendString:@"*"];
            }
                                  [queryPattern appendString:substring];
                              }];
        [queryPattern appendString:@"*"];
        self.queryGroups = queryGroups;

        NSError *error = nil;
        self.fetchedResultsController.fetchRequest.predicate =
                [NSPredicate predicateWithFormat:@"name LIKE[cd] %@ AND user == %@", queryPattern, [MPiOSAppDelegate get].activeUserOID];
        if (![self.fetchedResultsController performFetch:&error] || error)
            MPError( error, @"Couldn't fetch sites." );

        [self updateSites];
    }];
}

- (void)updateSites {

    PearlMainQueue( ^{
        [self.collectionView updateDataSource:self.dataSource
                                   toSections:[self createDataSource]
                                  reloadItems:@[ MPTransientPasswordItem ] completion:^(BOOL finished) {
                    for (MPSiteCell *cell in self.collectionView.visibleCells)
                        [cell setQueryGroups:self.queryGroups];
                }];
    } );
}

#pragma mark - Properties

- (NSString *)query {

    return [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (void)setQuery:(NSString *)query {

    self.searchBar.text = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    [self reloadSites];
}

- (NSFetchedResultsController *)fetchedResultsController {

    if (!_fetchedResultsController) {
        [MPiOSAppDelegate managedObjectContextForMainThreadPerformBlockAndWait:^(NSManagedObjectContext *mainContext) {
            NSFetchRequest *fetchRequest = [MPSiteEntity fetchRequest];
            fetchRequest.sortDescriptors = @[
                    [[NSSortDescriptor alloc] initWithKey:NSStringFromSelector( @selector( lastUsed ) ) ascending:NO]
            ];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"user == %@", [MPiOSAppDelegate get].activeUserOID];

            (self.fetchedResultsController = [[NSFetchedResultsController alloc]
                    initWithFetchRequest:fetchRequest managedObjectContext:mainContext
                      sectionNameKeyPath:nil cacheName:nil]).delegate = self;

            NSError *error = nil;
            if (![self.fetchedResultsController performFetch:&error] || error)
                MPError( error, @"Couldn't fetch sites." );
            [self updateSites];
        }];
        [self registerObservers];
    }

    return _fetchedResultsController;
}

- (void)setActive:(BOOL)active {

    [self setActive:active animated:NO completion:nil];
}

- (void)setActive:(BOOL)active animated:(BOOL)animated completion:(void ( ^ )(BOOL finished))completion {

    _active = active;

    [UIView animateWithDuration:animated? 0.4f: 0 animations:^{
        [self.navigationBarToTopConstraint withPriority:active? 1: UILayoutPriorityDefaultHigh];
        [self.sitesToBottomConstraint withPriority:active? 1: UILayoutPriorityDefaultHigh];
        [self.view layoutIfNeeded];
    }                completion:completion];
}

#pragma mark - Actions

- (IBAction)dismissPopdown:(id)sender {

    if (self.popdownVC)
        [[[MPPopdownSegue alloc] initWithIdentifier:@"unwind-popdown" source:self.popdownVC destination:self] perform];
    else
        self.popdownToTopConstraint.priority = UILayoutPriorityDefaultHigh;
}

- (IBAction)upgradeSpectre:(UIButton *)sender {

    [[MPiOSAppDelegate get] migrateFor:[MPiOSAppDelegate get].activeUserForMainThread];
}

#pragma mark - Private

- (void)updateSpectreAlerts {

    BOOL spectreInstalled = [UIApp canOpenURL:[[NSURL alloc] initWithString:@"spectre:"]];
    if (spectreInstalled) {
        self.spectreInstallAlert.visible = NO;
        self.spectreMigrateAlert.visible = YES;
    }
    else {
        self.spectreInstallAlert.visible = [MPiOSAppDelegate get].spectreViewController != nil;
        self.spectreMigrateAlert.visible = NO;
    }
}

@end
