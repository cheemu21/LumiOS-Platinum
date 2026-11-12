// The in-game cheats bubble (DM_CHEAT_BUBBLE=1: the launcher's Cheats row, offered for a profile with cheat_bubble on): a small round button over the game, next to the gamepad's menu
// button at the top centre, that the player can drag anywhere (its place is kept per game in NSUserDefaults). A tap opens a panel listing the loaded cheat file's cheats
// (hle_cheats.c: Documents/cheats/<build ID>.txt, which main.m fills from the app's dm/cheats) with a switch each; a switch calls dm_cheat_toggle, as the Mac's Cheats panel does,
// and the engine remembers the states for the next start. Sections (EdiZon markers or a .meta.tsv) become headings; a cheat the engine cannot run shows why and has no switch.
// The look follows the Brilliant touch layout (DmGamepad.m): translucent white glass, no colours, a sparkle for the symbol.
// On iOS the engine writes the game's data only (main's code pages are signed and cannot be written), so a code cheat shows the engine's note and stays off.
#import <UIKit/UIKit.h>
#include "dm.h"
#import "DmLayout.h"

static NSString *const k_bubble_pos = @"DmCheatBubble";   // NSUserDefaults: the bubble's centre as a fraction of the view (x, y)

@interface DmCheatPanel : UIView <UITableViewDataSource, UITableViewDelegate>
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
        UILabel *hint = [UILabel new]; hint.tag = 2; hint.text = @"tap outside to close"; hint.font = [UIFont systemFontOfSize:11.5]; hint.textColor = [UIColor colorWithWhite:1 alpha:0.7]; hint.textAlignment = NSTextAlignmentRight;
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
}
- (void)reload {
    _sections = [NSMutableArray new]; _rows = [NSMutableArray new];
    int n = dm_cheats_ncheats();
    for (int i = 0; i < n; i++) {
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
