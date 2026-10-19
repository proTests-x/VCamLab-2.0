#import "VCPApplicationSelectorController.h"
#import "../VCPreferences.h"

#import <notify.h>
#import <objc/message.h>

static CFStringRef const VCPPreferencesDomain = CFSTR("com.murkaska.virtualcampro");
static CFStringRef const VCPTargetBundleIdentifiersKey = CFSTR("targetBundleIdentifiers");
static CFStringRef const VCPPreferencesChangedNotification =
    CFSTR("com.murkaska.virtualcampro/preferences.changed");
static NSString * const VCPPreferencesPath =
    @"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist";

@interface VCPApplicationEntry : NSObject
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *detail;
@end

@implementation VCPApplicationEntry
@end

@interface VCPApplicationSelectorController () <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<VCPApplicationEntry *> *applications;
@property(nonatomic, copy) NSArray<VCPApplicationEntry *> *visibleApplications;
@property(nonatomic, strong) NSMutableSet<NSString *> *selectedBundleIdentifiers;
@property(nonatomic, strong) UISearchController *searchController;
@end

static id VCPObjectMessage(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *VCPStringProperty(id object, NSString *key) {
    @try {
        id value = [object valueForKey:key];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<NSString *> *VCPReadSelectedBundleIdentifiers(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        VCPTargetBundleIdentifiersKey,
        VCPPreferencesDomain);
    id bridged = CFBridgingRelease(value);
    if (![bridged isKindOfClass:NSArray.class]) {
        NSDictionary *direct = [NSDictionary dictionaryWithContentsOfFile:VCPPreferencesPath];
        bridged = direct[(__bridge NSString *)VCPTargetBundleIdentifiersKey];
    }
    if (![bridged isKindOfClass:NSArray.class]) return @[];

    NSMutableOrderedSet<NSString *> *clean = [NSMutableOrderedSet orderedSet];
    for (id candidate in (NSArray *)bridged) {
        if (![candidate isKindOfClass:NSString.class]) continue;
        NSString *identifier = [candidate
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (identifier.length == 0 || identifier.length > 255) continue;
        [clean addObject:identifier];
        if (clean.count >= 128) break;
    }
    return clean.array;
}

static void VCPWriteSelectedBundleIdentifiers(NSSet<NSString *> *identifiers) {
    NSArray<NSString *> *sorted = [[identifiers allObjects]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    CFPreferencesSetAppValue(VCPTargetBundleIdentifiersKey,
                             (__bridge CFArrayRef)sorted,
                             VCPPreferencesDomain);
    CFPreferencesAppSynchronize(VCPPreferencesDomain);
    [VCPreferences.sharedPreferences reload];
    [VCPreferences.sharedPreferences publishSharedConfiguration];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPPreferencesChangedNotification,
                                         NULL,
                                         NULL,
                                         true);
}

static VCPApplicationEntry *VCPEntry(NSString *identifier,
                                     NSString *name,
                                     NSString *detail) {
    VCPApplicationEntry *entry = [VCPApplicationEntry new];
    entry.bundleIdentifier = identifier;
    entry.displayName = name.length > 0 ? name : identifier;
    entry.detail = detail ?: @"";
    return entry;
}

static NSArray<VCPApplicationEntry *> *VCPLoadInstalledApplications(void) {
    NSMutableDictionary<NSString *, VCPApplicationEntry *> *byIdentifier =
        [NSMutableDictionary dictionary];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = VCPObjectMessage(workspaceClass, NSSelectorFromString(@"defaultWorkspace"));
    NSArray *proxies = VCPObjectMessage(workspace, NSSelectorFromString(@"allInstalledApplications"));
    if ([proxies isKindOfClass:NSArray.class]) {
        for (id proxy in proxies) {
            NSString *identifier = VCPStringProperty(proxy, @"applicationIdentifier");
            if (identifier.length == 0 || identifier.length > 255) continue;
            NSString *name = VCPStringProperty(proxy, @"localizedName");
            NSString *type = VCPStringProperty(proxy, @"applicationType");
            NSString *detail = [type isEqualToString:@"System"]
                ? @"Aplicación del sistema" : identifier;
            byIdentifier[identifier] = VCPEntry(identifier, name, detail);
        }
    }

    // These camera hosts are real processes but are not always returned by
    // LaunchServices as ordinary launchable applications.
    byIdentifier[@"com.apple.camera"] = VCPEntry(@"com.apple.camera",
                                                   @"Cámara del sistema",
                                                   @"UIImagePickerController y vistas remotas");
    byIdentifier[@"com.apple.WebKit.WebContent"] =
        VCPEntry(@"com.apple.WebKit.WebContent",
                 @"Contenido web (WebKit)",
                 @"Safari, WKWebView y getUserMedia");

    return [[byIdentifier allValues]
        sortedArrayUsingComparator:^NSComparisonResult(VCPApplicationEntry *left,
                                                        VCPApplicationEntry *right) {
            NSComparisonResult byName = [left.displayName
                localizedCaseInsensitiveCompare:right.displayName];
            return byName == NSOrderedSame
                ? [left.bundleIdentifier compare:right.bundleIdentifier]
                : byName;
        }];
}

@implementation VCPApplicationSelectorController

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:style];
    if (self) {
        _selectedBundleIdentifiers =
            [NSMutableSet setWithArray:VCPReadSelectedBundleIdentifiers()];
        _applications = VCPLoadInstalledApplications();
        _visibleApplications = _applications;
        self.title = @"Aplicaciones objetivo";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchResultsUpdater = self;
    self.searchController.searchBar.placeholder = @"Buscar nombre o bundle ID";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    VCPWriteSelectedBundleIdentifiers(self.selectedBundleIdentifiers);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : (NSInteger)self.visibleApplications.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Ámbito" : @"Aplicaciones instaladas";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    return @"Sin una selección, VCamPro conserva el comportamiento compatible anterior y se aplica a todas las apps. Cierra y vuelve a abrir las apps después de cambiar esta lista.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString * const identifier = @"VCPApplicationCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Todas las aplicaciones";
        cell.detailTextLabel.text = @"Modo compatible global";
        cell.accessoryType = self.selectedBundleIdentifiers.count == 0
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }

    VCPApplicationEntry *entry = self.visibleApplications[(NSUInteger)indexPath.row];
    cell.textLabel.text = entry.displayName;
    cell.detailTextLabel.text = entry.detail.length > 0
        ? entry.detail : entry.bundleIdentifier;
    cell.accessoryType = [self.selectedBundleIdentifiers containsObject:entry.bundleIdentifier]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self.selectedBundleIdentifiers removeAllObjects];
    } else {
        VCPApplicationEntry *entry = self.visibleApplications[(NSUInteger)indexPath.row];
        if ([self.selectedBundleIdentifiers containsObject:entry.bundleIdentifier]) {
            [self.selectedBundleIdentifiers removeObject:entry.bundleIdentifier];
        } else {
            [self.selectedBundleIdentifiers addObject:entry.bundleIdentifier];
        }
    }
    VCPWriteSelectedBundleIdentifiers(self.selectedBundleIdentifiers);
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) {
        self.visibleApplications = self.applications;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(
            VCPApplicationEntry *entry, NSDictionary *bindings) {
            return [entry.displayName localizedCaseInsensitiveContainsString:query] ||
                   [entry.bundleIdentifier localizedCaseInsensitiveContainsString:query];
        }];
        self.visibleApplications = [self.applications filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
}

@end
