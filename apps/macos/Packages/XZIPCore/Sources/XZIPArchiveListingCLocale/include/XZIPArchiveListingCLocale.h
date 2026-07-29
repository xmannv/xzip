#ifndef XZIP_ARCHIVE_LISTING_C_LOCALE_H
#define XZIP_ARCHIVE_LISTING_C_LOCALE_H

struct XZIPUTF8LocaleScope;

struct XZIPUTF8LocaleScope *XZIPBeginUTF8Locale(void);
void XZIPEndUTF8Locale(struct XZIPUTF8LocaleScope *scope);

#endif
