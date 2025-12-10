/**
 * CommentDeleteQueueable - Deletes comments from Jira asynchronously
 * 
 * @author Your Name
 * @date 2024
 */
public class CommentDeleteQueueable implements Queueable, Database.AllowsCallouts {
    
    private List<CommentDeleteJob> deleteJobs;
    private static final Integer TIMEOUT_MS = 120000;
    
    public CommentDeleteQueueable(List<CommentDeleteJob> deleteJobs) {
        this.deleteJobs = deleteJobs;
    }
    
    public void execute(QueueableContext context) {
        Integer successCount = 0;
        
        for(CommentDeleteJob job : deleteJobs) {
            try {
                Boolean deleted = deleteCommentFromJira(job.jiraKey, job.jiraCommentId);
                
                if(deleted) {
                    successCount++;
                    
                    // Delete the sync record
                    List<Case_Comment_Jira_Sync__c> syncs = [
                        SELECT Id 
                        FROM Case_Comment_Jira_Sync__c 
                        WHERE Case_Comment_ID__c = :job.salesforceCommentId
                        LIMIT 1
                    ];
                    
                    if(!syncs.isEmpty()) {
                        delete syncs[0];
                    }
                }
            } catch(Exception e) {
                System.debug(LoggingLevel.ERROR, 'Error deleting comment: ' + e.getMessage());
            }
        }
        
        System.debug('Successfully deleted ' + successCount + ' of ' + deleteJobs.size() + ' comments from Jira');
    }
    
    /**
     * Deletes a comment from Jira
     */
    private Boolean deleteCommentFromJira(String jiraKey, String commentId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Jira_Cloud/rest/api/3/issue/' + jiraKey + '/comment/' + commentId);
        req.setMethod('DELETE');
        req.setTimeout(TIMEOUT_MS);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if(res.getStatusCode() == 204) {
            System.debug('Successfully deleted comment ' + commentId + ' from Jira');
            return true;
        } else {
            System.debug(LoggingLevel.ERROR, 'Delete failed. Status: ' + res.getStatusCode());
            return false;
        }
    }
}