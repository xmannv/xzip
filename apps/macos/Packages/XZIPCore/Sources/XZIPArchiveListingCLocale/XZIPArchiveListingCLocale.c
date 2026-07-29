#include "XZIPArchiveListingCLocale.h"

#include <locale.h>
#include <stdlib.h>

struct XZIPUTF8LocaleScope {
    locale_t locale;
    locale_t previous;
};

struct XZIPUTF8LocaleScope *XZIPBeginUTF8Locale(void) {
    locale_t locale = newlocale(LC_CTYPE_MASK, "UTF-8", NULL);
    if (locale == NULL) {
        return NULL;
    }

    struct XZIPUTF8LocaleScope *scope = malloc(sizeof(*scope));
    if (scope == NULL) {
        freelocale(locale);
        return NULL;
    }

    scope->locale = locale;
    scope->previous = uselocale(locale);
    if (scope->previous == (locale_t)0) {
        freelocale(locale);
        free(scope);
        return NULL;
    }
    return scope;
}

void XZIPEndUTF8Locale(struct XZIPUTF8LocaleScope *scope) {
    if (scope == NULL) {
        return;
    }
    uselocale(scope->previous);
    freelocale(scope->locale);
    free(scope);
}
