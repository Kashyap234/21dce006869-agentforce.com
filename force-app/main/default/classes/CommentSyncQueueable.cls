/**
 * CommentSyncQueueable - Syncs comments asynchronously
 * * Uses Case_Comment_Jira_Sync__c object for tracking
 * * @author Your Name
 * @date 2024
 */
public class CommentSyncQueueable implements Queueable, Database.AllowsCallouts {
    
    private List<CommentSyncJob> syncJobs;
    
    public CommentSyncQueueable(List<CommentSyncJob> syncJobs) {
        this.syncJobs = syncJobs;
    }
    
    public void execute(QueueableContext context) {
        for(CommentSyncJob job : syncJobs) {
            try {
                // Get author name
                User author = [SELECT Name FROM User WHERE Id = :job.authorId LIMIT 1];
                String authorName = author.Name;
                
                Boolean success = false; // Default to false
                String jiraCommentId = null;
                
                // Check if sync record exists
                List<Case_Comment_Jira_Sync__c> existingSyncs = [
                    SELECT Id, Jira_Comment_ID__c 
                    FROM Case_Comment_Jira_Sync__c 
                    WHERE Case_Comment_ID__c = :job.commentId 
                    LIMIT 1
                ];
                
                // SCENARIO 1: It's an Update to a Salesforce Comment
                if(job.isUpdate && !existingSyncs.isEmpty()) {
                    jiraCommentId = existingSyncs[0].Jira_Comment_ID__c;
                    
                    // Logic: If we have a sync record but the ID is a placeholder (SYNCED_...), 
                    // it means the original create didn't finish properly. Treat as NEW.
                    if(String.isBlank(jiraCommentId) || jiraCommentId.startsWith('SYNCED_')) {
                        // First sync, create new comment
                        String newJiraId = JiraService.addCommentToJira(
                            job.jiraKey, 
                            job.commentText, 
                            authorName
                        );
                        
                        if(newJiraId != null) {
                            success = true;
                            // Pass the REAL Jira ID to the sync record
                            createSyncRecord(job.commentId, job.jiraKey, newJiraId);
                        }
                    } else {
                        // Standard Update: We have a real Jira ID, so update it.
                        success = JiraService.updateCommentInJira(
                            job.jiraKey,
                            jiraCommentId,
                            job.commentText,
                            authorName
                        );
                        
                        if(success) {
                            updateSyncRecord(job.commentId, job.jiraKey, jiraCommentId);
                        }
                    }
                } 
                // SCENARIO 2: It's a New Salesforce Comment
                else {
                    // New comment, create in Jira
                    // FIX: Capture String ID instead of Boolean
                    String newJiraId = JiraService.addCommentToJira(
                        job.jiraKey, 
                        job.commentText, 
                        authorName
                    );
                    
                    if(newJiraId != null) {
                        success = true;
                        // FIX: Pass the REAL Jira ID (3 arguments)
                        createSyncRecord(job.commentId, job.jiraKey, newJiraId);
                    }
                }
                
                if(success) {
                    System.debug('Successfully synced comment for Case ' + job.caseNumber);
                } else {
                    System.debug(LoggingLevel.WARN, 'Failed to sync comment for Case ' + job.caseNumber);
                }
                
            } catch(Exception e) {
                System.debug(LoggingLevel.ERROR, 'Error syncing comment: ' + e.getMessage());
                System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
            }
        }
    }
    
    /**
     * Creates a sync record with the REAL Jira ID
     */
    private void createSyncRecord(Id commentId, String jiraKey, String realJiraId) {
        try {
            Case_Comment_Jira_Sync__c syncRecord = new Case_Comment_Jira_Sync__c(
                Case_Comment_ID__c = commentId,
                Jira_Issue_Key__c = jiraKey,
                Jira_Comment_ID__c = realJiraId, // Use the real ID!
                Last_Synced__c = System.now()
            );
            insert syncRecord;
            System.debug('Created sync record for comment: ' + commentId + ' with Jira ID: ' + realJiraId);
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to create sync record: ' + e.getMessage());
        }
    }
    
    /**
     * Updates an existing sync record
     */
    private void updateSyncRecord(Id commentId, String jiraKey, String jiraCommentId) {
        try {
            List<Case_Comment_Jira_Sync__c> syncs = [
                SELECT Id 
                FROM Case_Comment_Jira_Sync__c 
                WHERE Case_Comment_ID__c = :commentId 
                LIMIT 1
            ];
            
            if(!syncs.isEmpty()) {
                Case_Comment_Jira_Sync__c syncRecord = syncs[0];
                syncRecord.Last_Synced__c = System.now();
                if(jiraCommentId != null) {
                    syncRecord.Jira_Comment_ID__c = jiraCommentId;
                }
                update syncRecord;
                System.debug('Updated sync record for comment: ' + commentId);
            }
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to update sync record: ' + e.getMessage());
        }
    }
}