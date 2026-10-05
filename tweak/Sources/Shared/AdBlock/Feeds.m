// Ad sections taken out of the feeds Home, Search and the page under the player are built from
// (EeveeSpotify's BrowsitaSectionStripper). A feed is one container field of sections, each a
// field 1 message; a section goes when its bytes name an ad, or a promotion and a surface for it.
//
// Fork: the page under the player is not that shape. Its list (scrollsita's NpvScrollResponse) came
// back unread and went on whole, the ad card with it: "Advertisement", a picture and a button under
// the player (device, 2026-10-05). It is read the way EeveeSpotify's later source reads it
// (SideloadLabs/EeveeSpotifyReincarnated, 2026-09-20, GPL-3.0): the bytes are walked as plain wire
// format, and of a field that repeats only the entries that name an ad are cut, the rest going back
// byte for byte. The card's words are put on by the client, so what names it on the wire is the host
// its tracking links point at.
#import "Core/SGCore.h"
#import "AdBlock.h"
#import "Protobuf.h"

static const char *const hardMarkers[] = {
    "spotify:ad:", "open.spotify.com/ad/", "ad-formats", "advertisement", "brand-ad", "sponsored", "marquee", "promoted",
    "home-ads", "adsproduct", "leavebehind", "leave-behind", "premium-upsell", "premium_upsell", "premiumupsell",
    "referralsupsellcard",
    // Where an ad's tracking links go (spotify.scrollsita.v1.EmbeddedAdCardTrackingUrls).
    "aet.spotify.com",
};
static const char *const intentMarkers[] = {
    "upsell", "upgrade", "subscribe", "premium", "promo", "promotion", "marketing", "offer",
};
static const char *const surfaceMarkers[] = {
    "banner", "card", "popup", "pop-up", "sheet", "interstitial", "promotion", "promo",
};
// The filter chips of Search carry "browse" and "chip" in their ids and are never the ad.
static const char *const keepMarkers[] = {"filter", "chip", "pillar", "browse:chips"};
// The page under the player holds cards of every kind, an artist's biography among them, and a word a
// biography may use is no mark of an ad there: only what an address or an id would say.
static const char *const cardMarkers[] = {
    "spotify:ad:", "open.spotify.com/ad/", "aet.spotify.com", "ad-formats", "brand-ad", "home-ads", "adsproduct",
    "leavebehind", "leave-behind", "premium-upsell", "premium_upsell", "premiumupsell", "referralsupsellcard",
};

#define COUNT(list) (sizeof(list) / sizeof(list[0]))

// ASCII, case-insensitive; the markers are lower case.
static BOOL contains(const uint8_t *bytes, size_t length, const char *needle) {
    size_t n = strlen(needle);
    for (size_t i = 0; i + n <= length; i++) {
        size_t k = 0;
        while (k < n && tolower(bytes[i + k]) == needle[k]) k++;
        if (k == n) return YES;
    }
    return NO;
}

static BOOL containsAny(const uint8_t *bytes, size_t length, const char *const markers[], size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (contains(bytes, length, markers[i])) return YES;
    }
    return NO;
}

static BOOL adSection(const uint8_t *bytes, size_t length) {
    if (containsAny(bytes, length, hardMarkers, COUNT(hardMarkers))) return YES;
    if (containsAny(bytes, length, keepMarkers, COUNT(keepMarkers))) return NO;
    return containsAny(bytes, length, intentMarkers, COUNT(intentMarkers)) && containsAny(bytes, length, surfaceMarkers, COUNT(surfaceMarkers));
}

#pragma mark - Home and Search

// `read` says whether the bytes were that container at all.
static NSData *strippedContainer(NSData *body, BOOL *read) {
    *read = NO;
    NSMutableArray<SGPBField *> *fields = SGPBParse(body);
    SGPBField *container = fields.firstObject;
    if (container.number != 1 || container.wire != 2) return nil;
    NSMutableArray<SGPBField *> *sections = SGPBParse(container.payload);
    if (!sections) return nil;
    for (SGPBField *section in sections) {
        if (section.number != 1 || section.wire != 2) return nil;
    }
    *read = YES;
    NSMutableArray<SGPBField *> *kept = [NSMutableArray array];
    for (SGPBField *section in sections) {
        if (adSection(section.payload.bytes, section.payload.length)) SGAdBlockCountOne(@"Feed sections");
        else [kept addObject:section];
    }
    if (kept.count == sections.count) return nil;
    SGLog(@"dropped %lu of %lu feed sections", (unsigned long)(sections.count - kept.count), (unsigned long)sections.count);
    container.payload = SGPBSerialize(kept);
    return SGPBSerialize(fields);
}

#pragma mark - any layout

typedef struct {
    uint64_t number;
    size_t start, end, tagLength;   // the field whole, and how much of it is its tag
    BOOL delimited;
    size_t valueStart, valueEnd;    // a length-delimited field's payload
} SGWireField;

static BOOL readVarint(const uint8_t *bytes, size_t at, size_t end, uint64_t *value, size_t *length) {
    uint64_t result = 0;
    for (size_t i = 0; i < 10 && at + i < end; i++) {
        uint8_t byte = bytes[at + i];
        result |= (uint64_t)(byte & 0x7f) << (7 * i);
        if (!(byte & 0x80)) {
            *value = result;
            *length = i + 1;
            return YES;
        }
    }
    return NO;
}

static void appendVarint(NSMutableData *out, uint64_t value) {
    do {
        uint8_t byte = value & 0x7f;
        value >>= 7;
        if (value) byte |= 0x80;
        [out appendBytes:&byte length:1];
    } while (value);
}

// The message in bytes[start, end) without the entries one of `markers` names; nil when it has none to
// lose, or is not a message. An entry of a field that repeats is cut on its own. A field that does not
// repeat is gone into, to reach the list inside it, and cut whole only when nothing inside can be and it
// lies inside an entry already.
// Only an ad named outright counts here, not a promotion and a surface for it: this reads layouts
// nobody has looked at, where "premium" beside "card" may be anything.
static NSData *withoutAds(const uint8_t *bytes, size_t start, size_t end, int depth, const char *const markers[], size_t markerCount,
                          NSUInteger *dropped) {
    if (depth >= 24 || end <= start) return nil;
    NSMutableData *list = [NSMutableData data];
    size_t at = start;
    while (at < end) {
        uint64_t tag, value;
        size_t tagLength, n;
        if (!readVarint(bytes, at, end, &tag, &tagLength)) return nil;
        SGWireField field = {tag >> 3, at, 0, tagLength, NO, 0, 0};
        if (field.number < 1 || field.number > 0x1FFFFFFF) return nil;
        at += tagLength;
        switch (tag & 7) {
            case 0:
                if (!readVarint(bytes, at, end, &value, &n)) return nil;
                at += n;
                break;
            case 1:
                if (end - at < 8) return nil;
                at += 8;
                break;
            case 5:
                if (end - at < 4) return nil;
                at += 4;
                break;
            case 2:
                if (!readVarint(bytes, at, end, &value, &n) || value > end - at - n) return nil;
                at += n;
                field.delimited = YES;
                field.valueStart = at;
                field.valueEnd = at + (size_t)value;
                at = field.valueEnd;
                break;
            default:
                return nil;
        }
        field.end = at;
        [list appendBytes:&field length:sizeof(field)];
    }
    NSUInteger count = list.length / sizeof(SGWireField);
    const SGWireField *fields = list.bytes;
    NSMutableIndexSet *cut = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSNumber *, NSData *> *rebuilt = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < count; i++) {
        SGWireField field = fields[i];
        if (!field.delimited) continue;
        if (!containsAny(bytes + field.valueStart, field.valueEnd - field.valueStart, markers, markerCount)) continue;
        NSUInteger alike = 0;
        for (NSUInteger k = 0; k < count; k++) {
            if (fields[k].number == field.number) alike++;
        }
        if (alike >= 2) {
            [cut addIndex:i];
            continue;
        }
        NSData *inner = withoutAds(bytes, field.valueStart, field.valueEnd, depth + 1, markers, markerCount, dropped);
        if (inner) rebuilt[@(i)] = inner;
        // Not the reply's own fields, nor the list in it: were one of those not read, every card would go.
        else if (depth >= 2) [cut addIndex:i];
    }
    if (!cut.count && !rebuilt.count) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:end - start];
    for (NSUInteger i = 0; i < count; i++) {
        SGWireField field = fields[i];
        NSData *inner = rebuilt[@(i)];
        if ([cut containsIndex:i]) {
            (*dropped)++;
        } else if (inner) {
            [out appendBytes:bytes + field.start length:field.tagLength];
            appendVarint(out, inner.length);
            [out appendData:inner];
        } else {
            [out appendBytes:bytes + field.start length:field.end - field.start];
        }
    }
    return out;
}

static NSData *strippedAnywhere(NSData *body, const char *const markers[], size_t markerCount, NSString *what) {
    NSUInteger dropped = 0;
    NSData *result = withoutAds(body.bytes, 0, body.length, 0, markers, markerCount, &dropped);
    if (!result || !dropped) return nil;
    for (NSUInteger i = 0; i < dropped; i++) SGAdBlockCountOne(@"Feed sections");
    SGLog(@"dropped %lu ad entries from %@, %lu -> %lu bytes", (unsigned long)dropped, what, (unsigned long)body.length, (unsigned long)result.length);
    return result;
}

NSData *SGStripFeed(NSData *body, NSString *path) {
    if (!body.length) return nil;
    // The page under the player never had Home's container, and read as one its bytes could be cut in
    // the wrong place: the wire pass alone.
    if ([path containsString:@"/scrollsita/"]) {
        NSData *result = strippedAnywhere(body, cardMarkers, COUNT(cardMarkers), @"the player's cards");
        static NSUInteger told;
        if (!result && told < 3) {
            told++;
            SGLog(@"the player's cards: no ad named in %lu bytes", (unsigned long)body.length);
        }
        return result;
    }
    BOOL read = NO;
    NSData *result = strippedContainer(body, &read);
    return read ? result : strippedAnywhere(body, hardMarkers, COUNT(hardMarkers), @"a feed of another layout");
}
