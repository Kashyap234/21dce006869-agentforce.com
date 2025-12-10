/**
 * AttachmentSyncQueueable - Downloads attachments from Jira asynchronously
 * 
 * Runs in background to allow HTTP callouts
 * 
 * @author Your Name
 * @date 2024
 */
public class AttachmentSyncQueueable implements Queueable, Database.AllowsCallouts {
    
    private Id caseId;
    private String attachmentId;
    private String contentUrl;
    private String filename;
    
    public AttachmentSyncQueueable(Id caseId, String attachmentId, String contentUrl, String filename) {
        this.caseId = caseId;
        this.attachmentId = attachmentId;
        this.contentUrl = contentUrl;
        this.filename = filename;
    }
    
    public void execute(QueueableContext context) {
        System.debug('Executing attachment sync for: ' + this.filename);
        
        JiraAttachmentSyncService.syncAttachmentFromJira(
            this.caseId,
            this.attachmentId,
            this.contentUrl,
            this.filename
        );
    }
}