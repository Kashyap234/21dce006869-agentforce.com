// ========================================
// 4. CleanupTelegramSessions.cls
// ========================================
global class CleanupTelegramSessions implements Schedulable {
    
    global void execute(SchedulableContext sc) {
        DateTime twoHoursAgo = DateTime.now().addHours(-2);
        
        List<Telegram_Session__c> oldSessionsList = [
            SELECT Id FROM Telegram_Session__c
            WHERE Last_Activity__c < :twoHoursAgo
        ];
        
        if (!oldSessionsList.isEmpty()) {
            delete oldSessionsList;
            System.debug('Cleaned up ' + oldSessionsList.size() + ' old sessions');
        }
    }
}