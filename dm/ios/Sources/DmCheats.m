// The in-game cheats bubble (DM_CHEAT_BUBBLE=1: the launcher's Cheats row, offered for a profile with cheat_bubble on): a small round button over the game, next to the gamepad's menu
// button at the top centre, that the player can drag anywhere (its place is kept per game in NSUserDefaults). A tap opens a panel listing the loaded cheat file's cheats
// (hle_cheats.c: Documents/cheats/<build ID>.txt, which main.m fills from the app's dm/cheats) with a switch each; a switch calls dm_cheat_toggle, as the Mac's Cheats panel does,
// and the engine remembers the states for the next start. Sections (EdiZon markers or a .meta.tsv) become headings; a cheat the engine cannot run shows why and has no switch.
// The look follows the Brilliant touch layout (DmGamepad.m): translucent white glass, no colours, a sparkle for the symbol.
// On iOS the engine writes the game's data only (main's code pages are signed and cannot be written), so a code cheat shows the engine's note and stays off.
#import <UIKit/UIKit.h>
#include "dm.h"
#import "DmLayout.h"
#ifndef DM_GAME_PKX
#define DM_GAME_PKX 0   // the Add a Pokémon form (profile pkx; game_profile.h): off where the profile does not say
#endif

static NSString *const k_bubble_pos = @"DmCheatBubble";   // NSUserDefaults: the bubble's centre as a fraction of the view (x, y)

@interface DmCheatPanel : UIView <UITableViewDataSource, UITableViewDelegate>
@end

// ---- Add a Pokémon (profile pkx on; hle_pkx.c makes it with the game's own code, on its main thread) ----
// The names come from the game's own message tables, put into the app at build time (dm/pkx.json, dm/tools/pkx_names.py); without them the form takes numbers
int dm_pkx_request(int monsno, int level, int shiny, int nature, int ivs, int form, int item, int ball, int dest);
void dm_pkx_status(char *out, size_t n);
int dm_pkx_pending(void);
static NSDictionary *pkx_names(void) {
    static NSDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ NSString *p = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"pkx.json"];
        NSData *j = [NSData dataWithContentsOfFile:p]; NSError *e = nil; id o = j ? [NSJSONSerialization JSONObjectWithData:j options:0 error:&e] : nil;
        d = [o isKindOfClass:NSDictionary.class] ? o : @{};
        id sp = d[@"species"];   // the log says what the form has, so an empty one explains itself
        LOG("front end: pkx names %s: %s, %lu species%s%s", p.fileSystemRepresentation, j ? "read" : "missing", (unsigned long)([sp isKindOfClass:NSArray.class] ? [sp count] : 0),
            e ? ", JSON error: " : "", e ? e.localizedDescription.UTF8String : ""); });
    return d;
}
@interface DmPkxForm : UIScrollView <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>   // scrolls: the whole form fits a phone held sideways
@property (nonatomic, copy) void (^done)(void);
@end
@implementation DmPkxForm {
    UITextField *_search, *_itemField; UITableView *_hits; NSArray<NSNumber *> *_found; int _hitsFor;   // _hitsFor: 0 species, 1 item
    UIStepper *_formStep; UILabel *_formLabel; UISegmentedControl *_dest; int _itemNo;
    UISlider *_level; UILabel *_levelLabel; UISwitch *_shiny, *_ivs; UIButton *_nature, *_ball, *_add, *_back; UILabel *_status;
    int _monsno, _natureNo, _ballNo; NSTimer *_poll;
}
static UILabel *pkx_label(UIView *v, NSString *s) { UILabel *l = [UILabel new]; l.text = s; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13]; [v addSubview:l]; return l; }
static UIButton *pkx_button(UIView *v, NSString *s) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setTitle:s forState:UIControlStateNormal]; b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14]; b.layer.cornerRadius = 9; b.layer.borderWidth = 1; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.5].CGColor;
    b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]; [v addSubview:b]; return b;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _natureNo = -1; _ballNo = 4;
        _search = [UITextField new]; _search.placeholder = @"Species: name or number"; _search.textColor = UIColor.whiteColor; _search.delegate = self;
        _search.attributedPlaceholder = [[NSAttributedString alloc] initWithString:_search.placeholder attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.5]}];
        _search.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; _search.layer.cornerRadius = 9; _search.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)]; _search.leftViewMode = UITextFieldViewModeAlways;
        _search.autocorrectionType = UITextAutocorrectionTypeNo; _search.returnKeyType = UIReturnKeyDone;
        [_search addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged]; [self addSubview:_search];
        _hits = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain]; _hits.dataSource = self; _hits.delegate = self; _hits.rowHeight = 30;
        _hits.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35]; _hits.layer.cornerRadius = 8; _hits.hidden = YES; [self addSubview:_hits];
        _levelLabel = pkx_label(self, @"Level 50"); _level = [UISlider new]; _level.minimumValue = 1; _level.maximumValue = 100; _level.value = 50;
        _level.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.85]; [_level addTarget:self action:@selector(levelChanged) forControlEvents:UIControlEventValueChanged]; [self addSubview:_level];
        pkx_label(self, @"Shiny").tag = 11; _shiny = [UISwitch new]; _shiny.onTintColor = [UIColor colorWithWhite:1 alpha:0.85]; [self addSubview:_shiny];
        pkx_label(self, @"Perfect IVs").tag = 12; _ivs = [UISwitch new]; _ivs.on = YES; _ivs.onTintColor = [UIColor colorWithWhite:1 alpha:0.85]; [self addSubview:_ivs];
        _nature = pkx_button(self, @"Nature: Random"); _nature.showsMenuAsPrimaryAction = YES; [self rebuildNatureMenu];
        _ball = pkx_button(self, @"Ball: Poké Ball"); _ball.showsMenuAsPrimaryAction = YES; [self rebuildBallMenu];
        _itemField = [UITextField new]; _itemField.textColor = UIColor.whiteColor; _itemField.delegate = self; _itemField.autocorrectionType = UITextAutocorrectionTypeNo; _itemField.returnKeyType = UIReturnKeyDone;
        _itemField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Held item (none)" attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.5]}];
        _itemField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12]; _itemField.layer.cornerRadius = 9; _itemField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)]; _itemField.leftViewMode = UITextFieldViewModeAlways;
        [_itemField addTarget:self action:@selector(searchChanged:) forControlEvents:UIControlEventEditingChanged]; [self addSubview:_itemField];
        _formLabel = pkx_label(self, @"Form 0"); _formStep = [UIStepper new]; _formStep.minimumValue = 0; _formStep.maximumValue = 63; _formStep.tintColor = UIColor.whiteColor;
        _formStep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2]; _formStep.layer.cornerRadius = 8; [_formStep addTarget:self action:@selector(formChanged) forControlEvents:UIControlEventValueChanged]; [self addSubview:_formStep];
        _dest = [[UISegmentedControl alloc] initWithItems:@[@"Party, then box", @"Box"]]; _dest.selectedSegmentIndex = 0;
        _dest.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.85]; [_dest setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
        [_dest setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.1 alpha:1]} forState:UIControlStateSelected]; [self addSubview:_dest];
        _add = pkx_button(self, @"Add"); [_add addTarget:self action:@selector(add) forControlEvents:UIControlEventTouchUpInside];
        _back = pkx_button(self, @"Back"); [_back addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
        NSUInteger nsp = [self list:@"species"].count;
        _status = pkx_label(self, nsp ? [NSString stringWithFormat:@"%lu species to pick from. The game makes it, as its own gifts; a full party sends it to a box.", (unsigned long)(nsp ? nsp - 1 : 0)]
                                      : @"The species names did not load: type a species number (25 is Pikachu)."); _status.numberOfLines = 2; _status.font = [UIFont systemFontOfSize:11.5]; _status.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, y = 4, half = (w - 8) / 2;
    _search.frame = CGRectMake(0, y, w, 32); y += 40;
    _levelLabel.frame = CGRectMake(0, y, 80, 30); _level.frame = CGRectMake(84, y, w - 84, 30); y += 36;
    [self viewWithTag:11].frame = CGRectMake(0, y, 60, 31); _shiny.frame = CGRectMake(60, y, 51, 31);
    [self viewWithTag:12].frame = CGRectMake(half + 8, y, 80, 31); _ivs.frame = CGRectMake(w - 51, y, 51, 31); y += 40;
    _nature.frame = CGRectMake(0, y, half, 32); _ball.frame = CGRectMake(half + 8, y, half, 32); y += 40;
    _itemField.frame = CGRectMake(0, y, w, 32); y += 40;
    _formLabel.frame = CGRectMake(0, y, 70, 32); _formStep.frame = CGRectMake(70, y, 94, 32); y += 40;
    _dest.frame = CGRectMake(0, y, w, 32); y += 40;
    _back.frame = CGRectMake(0, y, 70, 34); _add.frame = CGRectMake(78, y, w - 78, 34); y += 40;
    _status.frame = CGRectMake(0, y, w, 32); y += 36;
    self.contentSize = CGSizeMake(w, y);
    static int logged; if (!logged++) LOG("front end: pkx form laid out %.0fx%.0f, content %.0f tall", self.bounds.size.width, self.bounds.size.height, y);
    UIView *field = _hitsFor ? _itemField : _search;   // suggestions under the field being typed in
    _hits.frame = CGRectMake(0, CGRectGetMaxY(field.frame) + 4, w, MIN(150, MAX(60, self.contentSize.height - CGRectGetMaxY(field.frame) - 8)));
}
- (NSArray *)list:(NSString *)k { id v = pkx_names()[k]; return [v isKindOfClass:NSArray.class] ? v : @[]; }
- (void)rebuildNatureMenu {
    NSMutableArray *a = [NSMutableArray arrayWithObject:[UIAction actionWithTitle:@"Random" image:nil identifier:nil handler:^(UIAction *x) { (void)x; self->_natureNo = -1; [self->_nature setTitle:@"Nature: Random" forState:UIControlStateNormal]; }]];
    NSArray *n = [self list:@"natures"];
    for (int i = 0; i < 25; i++) { NSString *t = i < (int)n.count && [n[i] length] ? n[i] : [NSString stringWithFormat:@"Nature %d", i];
        [a addObject:[UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *x) { (void)x; self->_natureNo = i; [self->_nature setTitle:[@"Nature: " stringByAppendingString:t] forState:UIControlStateNormal]; }]]; }
    _nature.menu = [UIMenu menuWithChildren:a];
}
- (void)rebuildBallMenu {   // balls 1 to 16 are items 1 to 16 (their item numbers are the ball IDs)
    NSMutableArray *a = [NSMutableArray array]; NSArray *it = [self list:@"items"];
    for (int i = 1; i <= 16; i++) { NSString *t = i < (int)it.count && [it[i] length] ? it[i] : [NSString stringWithFormat:@"Ball %d", i];
        if (i == 4) [_ball setTitle:[@"Ball: " stringByAppendingString:t] forState:UIControlStateNormal];
        [a addObject:[UIAction actionWithTitle:t image:nil identifier:nil handler:^(UIAction *x) { (void)x; self->_ballNo = i; [self->_ball setTitle:[@"Ball: " stringByAppendingString:t] forState:UIControlStateNormal]; }]]; }
    _ball.menu = [UIMenu menuWithChildren:a];
}
- (void)levelChanged { _levelLabel.text = [NSString stringWithFormat:@"Level %d", (int)lroundf(_level.value)]; }
- (void)formChanged { _formLabel.text = [NSString stringWithFormat:@"Form %d", (int)_formStep.value]; }
- (void)searchChanged:(UITextField *)field {   // matches by name (prefix first) or by number, in species or items
    _hitsFor = field == _itemField; if (_hitsFor) _itemNo = 0; else _monsno = 0;
    NSString *q = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString; NSArray *sp = [self list:_hitsFor ? @"items" : @"species"];
    NSMutableArray *pre = [NSMutableArray array], *mid = [NSMutableArray array];
    if (q.length) {
        int num = q.intValue;
        if (num > 0) [pre addObject:@(num)];
        for (NSUInteger i = 1; i < sp.count && pre.count + mid.count < 40; i++) { NSString *n = [sp[i] lowercaseString]; if (!n.length || (int)i == num) continue;
            if ([n hasPrefix:q]) [pre addObject:@(i)]; else if ([n containsString:q]) [mid addObject:@(i)]; }
    }
    _found = [pre arrayByAddingObjectsFromArray:mid]; _hits.hidden = !_found.count; [_hits reloadData]; [self setNeedsLayout]; [self layoutIfNeeded]; [self bringSubviewToFront:_hits];
}
- (NSString *)nameOf:(int)n { NSArray *sp = [self list:_hitsFor ? @"items" : @"species"]; return n > 0 && n < (int)sp.count && [sp[n] length] ? sp[n] : [NSString stringWithFormat:@"#%d", n]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _found.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"h"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"h"];
    int n = _found[ip.row].intValue; c.textLabel.text = [NSString stringWithFormat:@"%@  #%d", [self nameOf:n], n]; c.textLabel.textColor = UIColor.whiteColor; c.textLabel.font = [UIFont systemFontOfSize:13];
    c.backgroundColor = UIColor.clearColor; return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    int n = _found[ip.row].intValue; UITextField *f = _hitsFor ? _itemField : _search; f.text = [self nameOf:n];
    if (_hitsFor) _itemNo = n; else _monsno = n;
    _hits.hidden = YES; [f resignFirstResponder];
}
- (BOOL)textFieldShouldReturn:(UITextField *)f { if (_found.count) [self tableView:_hits didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]; [f resignFirstResponder]; return YES; }
- (void)add {
    if (_monsno <= 0) { int n = _search.text.intValue; if (n > 0) _monsno = n; }
    if (_monsno <= 0) { _status.text = @"Pick a species first."; return; }
    if (!_itemNo && _itemField.text.intValue > 0) _itemNo = _itemField.text.intValue;
    if (!_itemField.text.length) _itemNo = 0;
    if (dm_pkx_request(_monsno, (int)lroundf(_level.value), _shiny.on, _natureNo, _ivs.on ? 6 : 0, (int)_formStep.value, _itemNo, _ballNo, (int)_dest.selectedSegmentIndex) == 0) _status.text = @"Adding… (the game makes it at its next frame)";
    [_poll invalidate];
    __weak DmPkxForm *ws = self;
    _poll = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *tm) { DmPkxForm *me = ws; if (!me) { [tm invalidate]; return; }
        char st[160]; dm_pkx_status(st, sizeof st); me->_status.text = [NSString stringWithUTF8String:st];
        if (!dm_pkx_pending()) { [tm invalidate]; [UIImpactFeedbackGenerator.new impactOccurredWithIntensity:0.6]; } }];
}
- (void)back { [_poll invalidate]; [_search resignFirstResponder]; [_itemField resignFirstResponder]; if (self.done) self.done(); }
@end

@interface DmCheatBubble : UIButton
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) DmCheatPanel *panel;
@end

@implementation DmCheatPanel {
    UITableView *_table;
    NSMutableArray<NSString *> *_sections;            // section titles in file order ("" = none)
    NSMutableArray<NSMutableArray<NSNumber *> *> *_rows;   // the cheats of each section (their index in the engine's list)
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
        self.layer.cornerRadius = 18; self.layer.borderWidth = 1.2; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = 0.35; self.layer.shadowRadius = 8; self.layer.shadowOffset = CGSizeMake(0, 2);
        UILabel *title = [UILabel new]; title.tag = 1;
        NSMutableAttributedString *t = [NSMutableAttributedString new];
        NSTextAttachment *spark = [NSTextAttachment textAttachmentWithImage:[[UIImage systemImageNamed:@"sparkles"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal]];
        [t appendAttributedString:[NSAttributedString attributedStringWithAttachment:spark]];
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:@"  Cheats" attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightBold], NSForegroundColorAttributeName: UIColor.whiteColor}]];
        title.attributedText = t; [self addSubview:title];
        if (DM_GAME_PKX) { UIButton *addp = pkx_button(self, @"+ Add a Pokémon"); addp.tag = 3; [addp addTarget:self action:@selector(openPkx) forControlEvents:UIControlEventTouchUpInside]; }
        UILabel *hint = [UILabel new]; hint.tag = 2; hint.text = DM_GAME_PKX ? @"" : @"tap outside to close"; hint.font = [UIFont systemFontOfSize:11.5]; hint.textColor = [UIColor colorWithWhite:1 alpha:0.7]; hint.textAlignment = NSTextAlignmentRight;
        [self addSubview:hint];
        _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
        _table.backgroundColor = UIColor.clearColor; _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.15]; _table.dataSource = self; _table.delegate = self;
        _table.rowHeight = 40; _table.sectionHeaderTopPadding = 0;
        [self addSubview:_table];
        [self reload];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    [self viewWithTag:1].frame = CGRectMake(18, 10, b.size.width / 2, 30);
    [self viewWithTag:2].frame = CGRectMake(b.size.width / 2, 10, b.size.width / 2 - 18, 30);
    _table.frame = CGRectMake(6, 46, b.size.width - 12, b.size.height - 52);
    [self viewWithTag:3].frame = CGRectMake(b.size.width - 146, 10, 128, 28);
    [self viewWithTag:4].frame = CGRectMake(16, 46, b.size.width - 32, b.size.height - 52);
}
- (void)openPkx {   // the form in place of the list; Back brings the list again
    DmPkxForm *f = [[DmPkxForm alloc] initWithFrame:CGRectZero]; f.tag = 4; __weak DmCheatPanel *ws = self; _table.hidden = YES; [self viewWithTag:3].hidden = YES;
    f.done = ^{ DmCheatPanel *me = ws; [[me viewWithTag:4] removeFromSuperview]; me->_table.hidden = NO; [me viewWithTag:3].hidden = NO; };
    [self addSubview:f]; [self setNeedsLayout];
}
- (void)reload {
    _sections = [NSMutableArray new]; _rows = [NSMutableArray new];
    int n = dm_cheats_ncheats();
    for (int i = 0; i < n; i++) {
        if (dm_cheat_flags_at(i) & (DM_CHEAT_SECTION_START | DM_CHEAT_SECTION_END)) continue;   // [--SectionStart:X--] / [--SectionEnd:X--]: they make the heading, not a row
        NSString *sec = [NSString stringWithUTF8String:dm_cheat_section_at(i)] ?: @"";
        if (!_sections.count || ![_sections.lastObject isEqualToString:sec]) { [_sections addObject:sec]; [_rows addObject:[NSMutableArray new]]; }
        [_rows.lastObject addObject:@(i)];
    }
    [_table reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return MAX(_sections.count, 1); }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _rows.count ? _rows[s].count : 1; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return s < (NSInteger)_sections.count && _sections[s].length ? _sections[s] : nil; }
- (void)tableView:(UITableView *)t willDisplayHeaderView:(UIView *)v forSection:(NSInteger)s {
    if ([v isKindOfClass:UITableViewHeaderFooterView.class]) { UITableViewHeaderFooterView *h = (UITableViewHeaderFooterView *)v; h.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.75];
        h.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration]; }
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.backgroundColor = UIColor.clearColor; c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.textColor = UIColor.whiteColor; c.textLabel.font = [UIFont systemFontOfSize:14]; c.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6]; c.detailTextLabel.font = [UIFont systemFontOfSize:11];
    if (!_rows.count) {
        c.textLabel.text = @"No cheats for this version"; c.detailTextLabel.text = [NSString stringWithFormat:@"Put %s.txt in the app's cheats folder", dm_cheats_build()]; c.accessoryView = nil; return c;
    }
    int i = _rows[ip.section][ip.row].intValue;
    c.textLabel.text = [NSString stringWithUTF8String:dm_cheat_name_at(i)];
    const char *why = dm_cheat_why_at(i), *note = dm_cheat_note_at(i);
    c.detailTextLabel.text = why && *why ? [NSString stringWithUTF8String:why] : note && *note ? [NSString stringWithUTF8String:note] : nil;
    if (dm_cheat_kind_at(i) == 3) { c.accessoryView = nil; c.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6]; return c; }   // a label (credits, a note): text, no switch
    if (dm_cheat_kind_at(i) == 1) { c.accessoryView = nil; c.detailTextLabel.text = @"always on"; return c; }   // a master code: the engine runs it before the others
    if (why && *why) { c.accessoryView = nil; c.textLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45]; return c; }   // the engine turned it off: unsupported here
    UISwitch *sw = [UISwitch new]; sw.on = dm_cheat_on_at(i); sw.tag = i;
    sw.onTintColor = [UIColor colorWithWhite:1 alpha:0.85]; sw.thumbTintColor = sw.on ? [UIColor colorWithWhite:0.17 alpha:1] : UIColor.whiteColor;
    sw.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16]; sw.layer.cornerRadius = 15.5;
    [sw addTarget:self action:@selector(flip:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw; return c;
}
- (void)flip:(UISwitch *)sw {
    if ((int)dm_cheat_on_at((int)sw.tag) != (int)sw.on) dm_cheat_toggle((int)sw.tag);   // the engine applies it at the next presented frame and saves the state
    [UIImpactFeedbackGenerator.new impactOccurredWithIntensity:0.5];
    [_table reloadData];   // a pair's other half, or a set-once cheat that turned itself off, shows its new state
}
@end

@implementation DmCheatBubble {
    CGPoint _grab; BOOL _moved;
}
+ (instancetype)bubbleIn:(UIView *)host {
    DmCheatBubble *b = [DmCheatBubble buttonWithType:UIButtonTypeCustom];
    b.host = host; b.bounds = CGRectMake(0, 0, 34, 34); b.layer.cornerRadius = 17;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16]; b.layer.borderWidth = 1.4; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    b.layer.shadowColor = UIColor.blackColor.CGColor; b.layer.shadowOpacity = 0.3; b.layer.shadowRadius = 3; b.layer.shadowOffset = CGSizeMake(0, 1);
    [b setImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:1 alpha:0.95]; b.accessibilityLabel = @"Cheats";
    [b addTarget:b action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:b action:@selector(drag:)]];
    return b;
}
- (CGPoint)defaultCentre {   // right of the gamepad's menu button at the top centre (DmGamepad.m: menu at the safe area's middle, 22 points down; − is at its left)
    UIEdgeInsets i = self.host.safeAreaInsets; CGRect s = UIEdgeInsetsInsetRect(self.host.bounds, UIEdgeInsetsMake(0, i.left, 0, i.right));
    CGFloat u = MIN(self.host.bounds.size.height / 430.0, 1.3);
    return CGPointMake(CGRectGetMidX(s) + 49 * u, i.top + 22 * u);
}
- (void)place {
    NSArray *p = [NSUserDefaults.standardUserDefaults arrayForKey:k_bubble_pos]; CGSize sz = self.host.bounds.size;
    self.center = p.count == 2 ? CGPointMake([p[0] doubleValue] * sz.width, [p[1] doubleValue] * sz.height) : self.defaultCentre;
    if (self.panel) [self layoutPanel];
}
- (void)drag:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.host]; CGSize sz = self.host.bounds.size;
    p.x = fmin(fmax(p.x, 20), sz.width - 20); p.y = fmin(fmax(p.y, 20), sz.height - 20);
    self.center = p;
    if (g.state == UIGestureRecognizerStateEnded) [NSUserDefaults.standardUserDefaults setObject:@[@(p.x / sz.width), @(p.y / sz.height)] forKey:k_bubble_pos];
}
- (void)layoutPanel {   // below the bubble when it is in the top half, above it otherwise; kept on screen
    CGSize sz = self.host.bounds.size; CGFloat w = MIN(320, sz.width - 32), h = MIN(320, sz.height - 32);
    CGFloat x = fmin(fmax(self.center.x - w / 2, 16), sz.width - w - 16);
    CGFloat y = self.center.y < sz.height / 2 ? self.center.y + 24 : self.center.y - 24 - h; y = fmin(fmax(y, 16), sz.height - h - 16);
    self.panel.superview.frame = self.host.bounds; self.panel.frame = CGRectMake(x, y, w, h);
}
- (void)tapped {
    if (self.panel) { [self close]; return; }
    UIControl *shade = [[UIControl alloc] initWithFrame:self.host.bounds];   // tap outside the panel: close
    shade.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28]; [shade addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    self.panel = [[DmCheatPanel alloc] initWithFrame:CGRectZero]; [shade addSubview:self.panel];
    [self.host insertSubview:shade belowSubview:self]; [self layoutPanel];
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.62]; self.tintColor = [UIColor colorWithWhite:0.12 alpha:0.92];
    dm_gamepad_reset();   // no key stays held under the panel
}
- (void)close {
    [self.panel.superview removeFromSuperview]; self.panel = nil;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16]; self.tintColor = [UIColor colorWithWhite:1 alpha:0.95];
}
@end

// front_ios.m: after the gamepad view, when the player turned Cheats on in the launcher (DM_CHEAT_BUBBLE=1)
static DmCheatBubble *g_bubble;
void dm_cheat_bubble_add(UIView *host) {
    const char *e = getenv("DM_CHEAT_BUBBLE"); if (!e || strcmp(e, "1")) return;
    g_bubble = [DmCheatBubble bubbleIn:host]; [host addSubview:g_bubble]; [g_bubble place];
    LOG("front end: cheats bubble on (DM_CHEAT_BUBBLE=1), %d cheats loaded for build %s", dm_cheats_ncheats(), dm_cheats_build());
}
void dm_cheat_bubble_layout(void) { [g_bubble place]; [g_bubble.superview bringSubviewToFront:g_bubble]; }
