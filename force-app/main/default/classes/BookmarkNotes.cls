/** Notes are append-only and stamped with time and author, which keeps an audit trail. */
public with sharing class BookmarkNotes {
    public static String append(String existing, String note) {
        String entry = '[' + System.now().format('yyyy-MM-dd HH:mm') + ' - ' + UserInfo.getName() + '] ' + note.trim();
        String combined = String.isBlank(existing) ? entry : existing + '\n' + entry;
        // Keep the newest notes if the field ever fills up.
        return combined.length() > 32768 ? combined.right(32768) : combined;
    }
}
