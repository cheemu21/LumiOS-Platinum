// Adding a Pokémon from the cheats panel (DmCheats.m) or a DM_CTL line ("pkx <species> <level> [shiny] [nature] [ivs] [form] [item] [ball]"), for Pokémon Brilliant Diamond
// 1.3.0 and Luminescent Platinum on it: the game makes it, as its own gift code does, so every field it derives is the game's (stats, level-up moves, ability, gender, OT, checksum).
// The request is queued here and carried out on the game's main thread at its next controller read (hle_hid.c states), where Unity and IL2CPP are in a state to run managed code:
//   InitialSpec (species, form, level, nature, perfect-IV count) → PokemonParam(InitialSpec) → held item, ball, rare type → poke_memo SetFromCapture (the met data from
//   PlayerWork's status and zone) → PlayerWork party AddMember → ZukanWork SetPoke(caught) → FieldPoketch AddPokemonHistory.
// That is the order of Luminescent's _ADD_POKEMON_EXTRA script command (Luminescent_ExLaunch, add_pokemon_extra.cpp); the addresses are from its headers for main build 94ceae32,
// and the allocator (main+0x2afc50, IL2CPP's object_new) is the one the game's 19 PokemonParam constructions call. Fixed addresses: the request is refused on any other main build.
// It goes into the party, or into the first empty box slot (BoxPokemonWork.UpdatePokemon, the game's own) when the party is full or a box is chosen; when every box is full that is
// reported and nothing changes. The class pointers are set by IL2CPP when the game first uses them (by the
// time a starter exists); before that the request is reported as not ready
#include "hle.h"
#include <pthread.h>

#define BUILD "94ceae325c205c4b"
enum {
    TI_INITIAL_SPEC = 0x4c5e700, TI_POKEMON_PARAM = 0x4c59c10,        // IL2CPP TypeInfo variables (Il2CppClass *)
    F_OBJECT_NEW = 0x2afc50,                                          // il2cpp object_new(klass)
    F_SPEC_CTOR = 0x20521d0, F_PARAM_CTOR_SPEC = 0x2055140,           // InitialSpec(), PokemonParam(InitialSpec)
    F_SET_ITEM = 0x2049680, F_SET_BALL = 0x204b840, F_SET_RARE = 0x204a920,   // CoreParam setters
    F_PW_STATUS = 0x2ce2d20, F_PW_ZONE = 0x2ceea50, F_PW_PARTY = 0x2ce2b50,   // PlayerWork.get_playerStatus / get_zoneID / get_playerParty
    F_MEMO_CAPTURE = 0x2bacb10, F_PARTY_ADD = 0x2055fa0,              // poke_memo.SetFromCapture, PokeParty.AddMember
    F_ZUKAN_SET = 0x17dc560, F_POKETCH_HISTORY = 0x1dba9c0,           // ZukanWork.SetPoke(PokemonParam, get), FieldPoketch.AddPokemonHistory
    F_BOX_GET = 0x1d2fe20, F_BOX_UPDATE = 0x1d30d60,                   // Dpr.Box.BoxPokemonWork.GetPokemon(tray, pos) / UpdatePokemon(pp, tray, pos): the save's box slots
    F_GET_MONSNO = 0x2044240,                                         // CoreParam.GetMonsNo: 0 for an empty slot
    TI_PLAYER_WORK = 0x4c59b58,                                       // PlayerWork: its parent's static fields hold the instance (the money cheat's path)
};
enum { BOX_SLOTS = 30 };   // a tray holds 30 (SaveBoxTrayData: 30 SerializedPokemonFull)
// InitialSpec fields (object header 0x10; Luminescent_ExLaunch InitialSpec.h): monsno i32 +0x38, formno u16 +0x3c (the game's own +0x3c store), level u16 +0x3e, seikaku u16 +0x42, talentVNum u8 +0x54
enum { S_MONSNO = 0x38, S_FORMNO = 0x3c, S_LEVEL = 0x3e, S_SEIKAKU = 0x42, S_TALENT_V = 0x54 };

typedef struct { int monsno, level, shiny, nature, ivs, form, item, ball, dest; } pkx_req;   // dest: 0 the party, or a box when it is full; 1 a box
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pkx_req g_req; static int g_pending;
static char g_status[160] = "";

static module_t *main_mod(void) { for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) return &g_mod[i]; return NULL; }
static void status(const char *fmt, ...) {
    va_list a; va_start(a, fmt); pthread_mutex_lock(&g_mu); vsnprintf(g_status, sizeof g_status, fmt, a); pthread_mutex_unlock(&g_mu); va_end(a);
    LOG("pkx: %s", g_status);
}

// The front end's request (any thread): 0 queued, -1 refused (with the reason in the status)
int dm_pkx_request(int monsno, int level, int shiny, int nature, int ivs, int form, int item, int ball, int dest) {
    module_t *m = main_mod();
    if (!m || strncasecmp(m->build_id, BUILD, 16)) { status("adding Pokémon needs main build %s (this is %s)", BUILD, m ? m->build_id : "?"); return -1; }
    if (monsno < 1 || monsno > 1025 || level < 1 || level > 100) { status("species 1-1025 and level 1-100, not %d / %d", monsno, level); return -1; }
    pthread_mutex_lock(&g_mu);
    if (form < 0 || form > 63 || item < 0 || item > 4095) { pthread_mutex_unlock(&g_mu); status("form 0-63 and item 0-4095, not %d / %d", form, item); return -1; }
    g_req = (pkx_req){monsno, level, shiny, nature, ivs, form, item, ball, dest}; g_pending = 1; snprintf(g_status, sizeof g_status, "queued: species %d, level %d", monsno, level);
    pthread_mutex_unlock(&g_mu);
    return 0;
}
// The last result, for the panel (copies it out)
void dm_pkx_status(char *out, size_t n) { pthread_mutex_lock(&g_mu); snprintf(out, n, "%s", g_status); pthread_mutex_unlock(&g_mu); }
int dm_pkx_pending(void) { return g_pending; }

// The number of box trays: the length of PlayerWork's SaveBoxTrayData[] (Luminescent may change the game's 40), found by its class name among the instance's fields so no field offset
// is assumed; 0 when it is not found (no box is then used)
static int tray_count(uint8_t *b) {
    uint8_t *K = *(uint8_t **)(b + TI_PLAYER_WORK); if (!K) return 0;
    uint8_t *P = *(uint8_t **)(K + 0x58); if (!P) return 0;                 // Il2CppClass.parent
    uint8_t *sf = *(uint8_t **)(P + 0xb8); if (!sf) return 0;               // its static fields
    uint8_t *inst = *(uint8_t **)sf; if (!inst) return 0;
    for (int off = 0x10; off < 0x1000; off += 8) {
        uint8_t *v = *(uint8_t **)(inst + off); uintptr_t u = (uintptr_t)v;
        if (u < 0x10000 || (u & 7)) continue;
        uint8_t *k = *(uint8_t **)v; if ((uintptr_t)k < 0x10000 || ((uintptr_t)k & 7)) continue;
        const char *nm = *(const char **)(k + 0x10); if ((uintptr_t)nm < 0x10000) continue;   // Il2CppClass.name
        if (!strcmp(nm, "SaveBoxTrayData[]")) return (int)*(uint64_t *)(v + 0x18);          // Il2CppArray.max_length
    }
    return 0;
}
// The first empty box slot (species 0), tray-major; -1 when every box is full
static int box_free_slot(uint8_t *b, int trays) {
    void *(*get)(int32_t, int32_t, void *) = (void *)(b + F_BOX_GET); int32_t (*monsno)(void *, void *) = (void *)(b + F_GET_MONSNO);
    for (int t = 0; t < trays; t++) for (int p = 0; p < BOX_SLOTS; p++) {
        void *pp = get(t, p, NULL);
        if (!pp || monsno(pp, NULL) == 0) return t * BOX_SLOTS + p;
    }
    return -1;
}

// On the game's main thread (hle_hid.c, each controller read): carry out a queued request
void dm_pkx_tick(void) {
    if (!g_pending) return;
    char nm[64] = ""; extern int thr_name_of(pthread_t, char *, size_t);
    if (!thr_name_of(pthread_self(), nm, sizeof nm) || !strstr(nm, "main thread")) return;   // Unity's main thread only
    pthread_mutex_lock(&g_mu); pkx_req r = g_req; g_pending = 0; pthread_mutex_unlock(&g_mu);
    module_t *m = main_mod(); uint8_t *b = m->base;
    void *spec_class = *(void **)(b + TI_INITIAL_SPEC), *param_class = *(void **)(b + TI_POKEMON_PARAM);
    if (!spec_class || !param_class) { status("the game has not made a Pokémon yet: try again once you have one"); return; }
    void *(*object_new)(void *) = (void *)(b + F_OBJECT_NEW);
    void *spec = object_new(spec_class);
    if (!spec) { status("could not allocate an InitialSpec"); return; }
    ((void (*)(void *, void *))(b + F_SPEC_CTOR))(spec, NULL);
    uint8_t *s = spec;
    *(int32_t *)(s + S_MONSNO) = r.monsno; *(uint16_t *)(s + S_LEVEL) = (uint16_t)r.level;
    if (r.form > 0) *(uint16_t *)(s + S_FORMNO) = (uint16_t)r.form;
    if (r.nature >= 0 && r.nature < 25) *(uint16_t *)(s + S_SEIKAKU) = (uint16_t)r.nature;
    if (r.ivs > 0) *(uint8_t *)(s + S_TALENT_V) = (uint8_t)(r.ivs > 6 ? 6 : r.ivs);   // how many IVs are 31
    void *pp = object_new(param_class);
    if (!pp) { status("could not allocate a PokemonParam"); return; }
    ((void (*)(void *, void *, void *))(b + F_PARAM_CTOR_SPEC))(pp, spec, NULL);
    if (r.item > 0) ((void (*)(void *, uint16_t, void *))(b + F_SET_ITEM))(pp, (uint16_t)r.item, NULL);
    ((void (*)(void *, uint32_t, void *))(b + F_SET_BALL))(pp, (uint32_t)(r.ball > 0 ? r.ball : 4), NULL);   // 4: Poké Ball
    ((void (*)(void *, uint8_t, void *))(b + F_SET_RARE))(pp, (uint8_t)(r.shiny ? 1 : 0), NULL);           // CAPTURED (shiny) / NOT_RARE
    void *st = ((void *(*)(void *))(b + F_PW_STATUS))(NULL);
    int32_t zone = ((int32_t (*)(void *))(b + F_PW_ZONE))(NULL);
    ((void (*)(void *, void *, uint32_t, void *))(b + F_MEMO_CAPTURE))(pp, st, (uint32_t)zone, NULL);
    char where[64] = "";
    void *party = r.dest == 1 ? NULL : ((void *(*)(void *))(b + F_PW_PARTY))(NULL);
    if (party && (((int (*)(void *, void *, void *))(b + F_PARTY_ADD))(party, pp, NULL) & 1))
        snprintf(where, sizeof where, "your party (%u in it now)", *(uint32_t *)((uint8_t *)party + 0x18));   // PokeParty.m_memberCount (object header 0x10, after m_member)
    else {   // the box: chosen, or the party is full / not made yet
        int trays = tray_count(b);
        if (!trays) { status("no boxes found yet (start or load a game first)"); return; }
        int slot = box_free_slot(b, trays);
        if (slot < 0) { status("every box is full (%d of them): make room, then add again", trays); return; }
        ((void (*)(void *, int32_t, int32_t, void *))(b + F_BOX_UPDATE))(pp, slot / BOX_SLOTS, slot % BOX_SLOTS, NULL);
        snprintf(where, sizeof where, "box %d, slot %d", slot / BOX_SLOTS + 1, slot % BOX_SLOTS + 1);
    }
    ((void (*)(void *, int32_t, void *))(b + F_ZUKAN_SET))(pp, 3, NULL);   // registered as caught
    ((void (*)(void *, void *))(b + F_POKETCH_HISTORY))(pp, NULL);
    status("added species %d%s at level %d%s%s to %s", r.monsno, r.form ? " (a form)" : "", r.level, r.shiny ? ", shiny" : "", r.item ? ", holding an item" : "", where);
}
