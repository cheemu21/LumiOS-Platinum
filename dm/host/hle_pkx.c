// Adding a Pokémon from the cheats panel (DmCheats.m) or a DM_CTL line ("pkx <species> <level> [shiny] [nature] [ivs] [form] [item] [ball]"), for Pokémon Brilliant Diamond
// 1.3.0 and Luminescent Platinum on it: the game makes it, as its own gift code does, so every field it derives is the game's (stats, level-up moves, ability, gender, OT, checksum).
// The request is queued here and carried out on the game's main thread at its next controller read (hle_hid.c states), where Unity and IL2CPP are in a state to run managed code:
//   InitialSpec (species, form, level, nature, perfect-IV count) → PokemonParam(InitialSpec) → held item, ball, rare type → poke_memo SetFromCapture (the met data from
//   PlayerWork's status and zone) → PlayerWork party AddMember → ZukanWork SetPoke(caught) → FieldPoketch AddPokemonHistory.
// That is the order of Luminescent's _ADD_POKEMON_EXTRA script command (Luminescent_ExLaunch, add_pokemon_extra.cpp); the addresses are from its headers for main build 94ceae32,
// and the allocator (main+0x2afc50, IL2CPP's object_new) is the one the game's 19 PokemonParam constructions call. Fixed addresses: the request is refused on any other main build.
// It goes into the party, so it needs a free party slot; a full party is reported and nothing changes. The class pointers are set by IL2CPP when the game first uses them (by the
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
};
// InitialSpec fields (object header 0x10; Luminescent_ExLaunch InitialSpec.h): monsno i32 +0x38, formno u16 +0x3c (the game's own +0x3c store), level u16 +0x3e, seikaku u16 +0x42, talentVNum u8 +0x54
enum { S_MONSNO = 0x38, S_FORMNO = 0x3c, S_LEVEL = 0x3e, S_SEIKAKU = 0x42, S_TALENT_V = 0x54 };

typedef struct { int monsno, level, shiny, nature, ivs, form, item, ball; } pkx_req;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pkx_req g_req; static int g_pending;
static char g_status[160] = "";

static module_t *main_mod(void) { for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) return &g_mod[i]; return NULL; }
static void status(const char *fmt, ...) {
    va_list a; va_start(a, fmt); pthread_mutex_lock(&g_mu); vsnprintf(g_status, sizeof g_status, fmt, a); pthread_mutex_unlock(&g_mu); va_end(a);
    LOG("pkx: %s", g_status);
}

// The front end's request (any thread): 0 queued, -1 refused (with the reason in the status)
int dm_pkx_request(int monsno, int level, int shiny, int nature, int ivs, int form, int item, int ball) {
    module_t *m = main_mod();
    if (!m || strncasecmp(m->build_id, BUILD, 16)) { status("adding Pokémon needs main build %s (this is %s)", BUILD, m ? m->build_id : "?"); return -1; }
    if (monsno < 1 || monsno > 1025 || level < 1 || level > 100) { status("species 1-1025 and level 1-100, not %d / %d", monsno, level); return -1; }
    pthread_mutex_lock(&g_mu);
    g_req = (pkx_req){monsno, level, shiny, nature, ivs, form, item, ball}; g_pending = 1; snprintf(g_status, sizeof g_status, "queued: species %d, level %d", monsno, level);
    pthread_mutex_unlock(&g_mu);
    return 0;
}
// The last result, for the panel (copies it out)
void dm_pkx_status(char *out, size_t n) { pthread_mutex_lock(&g_mu); snprintf(out, n, "%s", g_status); pthread_mutex_unlock(&g_mu); }
int dm_pkx_pending(void) { return g_pending; }

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
    void *party = ((void *(*)(void *))(b + F_PW_PARTY))(NULL);
    if (!party) { status("no party yet (start or load a game first)"); return; }
    int ok = ((int (*)(void *, void *, void *))(b + F_PARTY_ADD))(party, pp, NULL) & 1;
    if (!ok) { status("your party is full: make room, then add again"); return; }
    ((void (*)(void *, int32_t, void *))(b + F_ZUKAN_SET))(pp, 3, NULL);   // registered as caught
    ((void (*)(void *, void *))(b + F_POKETCH_HISTORY))(pp, NULL);
    uint32_t count = *(uint32_t *)((uint8_t *)party + 0x18);   // PokeParty.m_memberCount (object header 0x10, after m_member)
    status("added species %d at level %d%s to your party (%u in it now)", r.monsno, r.level, r.shiny ? ", shiny" : "", count);
}
