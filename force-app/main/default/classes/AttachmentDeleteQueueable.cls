/**
 * AttachmentDeleteQueueable - Deletes attachments from Jira
 * 
 * Purpose: When files are deleted from Salesforce, delete them from Jira too
 * 
 * How it works:
 * 1. Gets all attachments on the Jira issue
 * 2. Finds matching filenames
 * 3. Deletes them via API
 * 
 * @author Your Name
 * @date 2024
 */
public class AttachmentDeleteQueueable implements Queueable, Database.AllowsCallouts {
    
    private String jiraKey;
    private List<String> filenamesToDelete;
    private static final Integer TIMEOUT_MS = 120000;
    
    public AttachmentDeleteQueueable(String jiraKey, List<String> filenamesToDelete) {
        this.jiraKey = jiraKey;
        this.filenamesToDelete = filenamesToDelete;
    }
    
    public void execute(QueueableContext context) {
        try {
            System.debug('Deleting attachments from Jira issue: ' + this.jiraKey);
            System.debug('Files to delete: ' + this.filenamesToDelete);
            
            // Step 1: Get all attachments on the Jira issue
            List<JiraAttachment> attachments = getJiraAttachments();
            
            if(attachments == null || attachments.isEmpty()) {
                System.debug('No attachments found on Jira issue');
                return;
            }
            
            // Step 2: Find matching attachments
            Integer deleteCount = 0;
            for(JiraAttachment att : attachments) {
                if(this.filenamesToDelete.contains(att.filename)) {
                    Boolean deleted = deleteAttachment(att.id);
                    if(deleted) {
                        deleteCount++;
                        System.debug('Deleted: ' + att.filename);
                    }
                }
            }
            
            System.debug('Successfully deleted ' + deleteCount + ' of ' + this.filenamesToDelete.size() + ' attachments');
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error deleting attachments: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
        }
    }
    
    /**
     * Gets all attachments on a Jira issue
     */
    private List<JiraAttachment> getJiraAttachments() {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Jira_Cloud/rest/api/3/issue/' + this.jiraKey + '?fields=attachment');
        req.setMethod('GET');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if(res.getStatusCode() == 200) {
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> fields = (Map<String, Object>) response.get('fields');
            List<Object> attachmentsList = (List<Object>) fields.get('attachment');
            
            if(attachmentsList == null || attachmentsList.isEmpty()) {
                return new List<JiraAttachment>();
            }
            
            // Parse attachments
            List<JiraAttachment> result = new List<JiraAttachment>();
            for(Object attObj : attachmentsList) {
                Map<String, Object> att = (Map<String, Object>) attObj;
                result.add(new JiraAttachment(
                    (String) att.get('id'),
                    (String) att.get('filename')
                ));
            }
            
            return result;
        } else {
            System.debug(LoggingLevel.ERROR, 'Failed to get attachments. Status: ' + res.getStatusCode());
            return null;
        }
    }
    
    /**
     * Deletes a single attachment from Jira
     */
    private Boolean deleteAttachment(String attachmentId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Jira_Cloud/rest/api/3/attachment/' + attachmentId);
        req.setMethod('DELETE');
        req.setTimeout(TIMEOUT_MS);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if(res.getStatusCode() == 204) {
            return true;
        } else {
            System.debug(LoggingLevel.ERROR, 'Delete failed. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody());
            return false;
        }
    }
    
    /**
     * Inner class to hold Jira attachment data
     */
    public class JiraAttachment {
        public String id;
        public String filename;
        
        public JiraAttachment(String id, String filename) {
            this.id = id;
            this.filename = filename;
        }
    }
}