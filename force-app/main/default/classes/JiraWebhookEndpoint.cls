/**
 * JiraWebhookEndpoint - FIXED Case Lookup Version
 * 
 * Key Fixes:
 * 1. Improved Case lookup with trimming and case-insensitive search
 * 2. Better error messages showing BOTH the Jira key we're searching for AND what exists in SF
 * 3. Handles edge cases like whitespace
 * 
 * @author Your Name
 * @date 2024
 */
@RestResource(urlMapping='/jira/webhook')
global without sharing class JiraWebhookEndpoint {
    
    @HttpPost
    global static WebhookResponse handleWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        
        try {
            // Validate authentication
            if(!validateAuthentication(req)) {
                res.statusCode = 401;
                return new WebhookResponse(false, 'Authentication failed');
            }
            
            // Parse request
            String requestBody = req.requestBody.toString();
            System.debug('Jira Webhook received: ' + requestBody);
            
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            
            // Get webhook event type
            String webhookEvent = (String) payload.get('webhookEvent');
            System.debug('Webhook event type: ' + webhookEvent);
            
            // Route to appropriate handler
            if(webhookEvent == 'jira:issue_updated' || webhookEvent == 'issue_updated') {
                return handleIssueUpdated(payload, res);
            }
            else if(webhookEvent == 'jira:attachment_created' || webhookEvent == 'attachment_created') {
                return handleDirectAttachmentEvent(payload, res);
            } 
            else if(webhookEvent == 'jira:issue_comment_created' || webhookEvent == 'comment_created') {
                return handleCommentCreated(payload, res);
            }
            else if(webhookEvent == 'jira:issue_comment_updated' || webhookEvent == 'comment_updated') {
                return handleCommentUpdated(payload, res);
            }
            else if(webhookEvent == 'jira:issue_comment_deleted' || webhookEvent == 'comment_deleted') {
                return handleCommentDeleted(payload, res);
            }
            else {
                String msg = 'Event type not handled: ' + webhookEvent;
                System.debug(LoggingLevel.WARN, msg);
                return new WebhookResponse(true, msg);
            }
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Webhook error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }
    
    /**
     * Handles issue updates (status changes, attachments, deletions)
     */
    private static WebhookResponse handleIssueUpdated(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) {
            throw new WebhookException('Missing issue data');
        }
        
        String jiraKey = (String) issue.get('key');
        
        // Check event type
        if(isAttachmentAdded(payload)) {
            return handleAttachmentAdded(payload, jiraKey, res);
        }
        
        if(isAttachmentDeleted(payload)) {
            return handleAttachmentDeleted(payload, jiraKey, res);
        }
        
        // Status change logic
        if(!isStatusChanged(payload)) {
            return new WebhookResponse(true, 'No relevant changes');
        }
        
        Map<String, Object> fields = (Map<String, Object>) issue.get('fields');
        Map<String, Object> status = (Map<String, Object>) fields.get('status');
        String jiraStatus = (String) status.get('name');
        
        System.debug('Processing status change: ' + jiraKey + ' → ' + jiraStatus);
        
        String result = JiraWebhookService.updateCaseFromJira(jiraKey, jiraStatus);
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    /**
     * Handles attachment additions from Jira
     */
    private static WebhookResponse handleAttachmentAdded(Map<String, Object> payload, String jiraKey, RestResponse res) {
        System.debug('Processing attachment addition for: ' + jiraKey);
        
        try {
            // FIXED: Better Case lookup with debugging
            Case targetCase = findCaseByJiraKey(jiraKey);
            
            if(targetCase == null) {
                String msg = 'ERROR: No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.ERROR, msg);
                
                // Show what DOES exist in Salesforce for debugging
                debugExistingCases();
                
                res.statusCode = 200; // Return 200 so Jira doesn't retry
                return new WebhookResponse(false, msg);
            }
            
            System.debug('✓ Found Case: ' + targetCase.CaseNumber + ' (ID: ' + targetCase.Id + ')');
            
            // Get attachment info
            Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
            Map<String, Object> fields = (Map<String, Object>) issue.get('fields');
            List<Object> attachments = (List<Object>) fields.get('attachment');
            
            if(attachments == null || attachments.isEmpty()) {
                return new WebhookResponse(true, 'No attachments in payload');
            }
            
            // Get the NEWLY ADDED attachment (from changelog)
            String newAttachmentId = getNewAttachmentId(payload);
            
            if(String.isBlank(newAttachmentId)) {
                return new WebhookResponse(true, 'Could not identify new attachment');
            }
            
            // Find the attachment details
            Map<String, Object> newAttachment = null;
            for(Object attObj : attachments) {
                Map<String, Object> att = (Map<String, Object>) attObj;
                if(att.get('id') == newAttachmentId) {
                    newAttachment = att;
                    break;
                }
            }
            
            if(newAttachment == null) {
                return new WebhookResponse(true, 'Attachment not found in issue fields');
            }
            
            String attachmentId = (String) newAttachment.get('id');
            String filename = (String) newAttachment.get('filename');
            String contentUrl = (String) newAttachment.get('content');
            
            System.debug('✓ New attachment: ' + filename + ' (ID: ' + attachmentId + ')');
            
            // Queue the sync
            System.enqueueJob(new AttachmentSyncQueueable(
                targetCase.Id, 
                attachmentId, 
                contentUrl, 
                filename
            ));
            
            res.statusCode = 200;
            return new WebhookResponse(true, 'Attachment sync queued: ' + filename);
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error handling attachment: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }

    /**
     * Handles direct attachment_created events
     * Added Null Check to prevent crashes when 'issue' data is missing
     */
    private static WebhookResponse handleDirectAttachmentEvent(Map<String, Object> payload, RestResponse res) {
        try {
            // 1. SAFEGUARD: Check if 'issue' exists before accessing it
            if (!payload.containsKey('issue') || payload.get('issue') == null) {
                String msg = 'Skipping attachment_created event: Payload missing "issue" object. Relying on issue_updated event instead.';
                System.debug(LoggingLevel.WARN, msg);
                res.statusCode = 200; // Respond 200 to stop Jira from retrying this unusable event
                return new WebhookResponse(true, msg);
            }

            // 2. Get Jira Key
            Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
            String jiraKey = (String) issue.get('key');
            
            System.debug('Processing direct attachment event for: ' + jiraKey);
    
            // 3. Find the Case
            Case targetCase = findCaseByJiraKey(jiraKey);
            if(targetCase == null) {
                String msg = 'ERROR: No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.ERROR, msg);
                // Tip: Ensure you have a Case in Salesforce with Jira_Issue_Key__c = jiraKey
                res.statusCode = 200; 
                return new WebhookResponse(false, msg);
            }
    
            // 4. Extract attachment details
            Map<String, Object> attachment = (Map<String, Object>) payload.get('attachment');
            if (attachment == null) {
                 return new WebhookResponse(true, 'No attachment data found');
            }
    
            String attachmentId = (String) attachment.get('id');
            String filename = (String) attachment.get('filename');
            String contentUrl = (String) attachment.get('content');
    
            System.debug('Queueing sync for: ' + filename + ' (ID: ' + attachmentId + ')');
    
            // 5. Queue the download
            System.enqueueJob(new AttachmentSyncQueueable(
                targetCase.Id, 
                attachmentId, 
                contentUrl, 
                filename
            ));
    
            res.statusCode = 200;
            return new WebhookResponse(true, 'Attachment sync queued: ' + filename);
    
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in direct attachment handler: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }
    
    /**
     * Handles attachment deletions from Jira
     */
    private static WebhookResponse handleAttachmentDeleted(Map<String, Object> payload, String jiraKey, RestResponse res) {
        System.debug('Processing attachment deletion for: ' + jiraKey);
        
        try {
            Case targetCase = findCaseByJiraKey(jiraKey);
            
            if(targetCase == null) {
                String msg = 'No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.WARN, msg);
                res.statusCode = 200;
                return new WebhookResponse(true, msg);
            }
            
            // Get deleted filename from changelog
            String deletedFilename = getDeletedFilename(payload);
            
            if(String.isBlank(deletedFilename)) {
                return new WebhookResponse(true, 'Could not identify deleted filename');
            }
            
            System.debug('Deleted filename: ' + deletedFilename);
            
            // Find and delete matching ContentDocumentLink
            List<ContentDocumentLink> links = [
                SELECT Id, ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :targetCase.Id
            ];
            
            Id docIdToDelete = null;
            for(ContentDocumentLink link : links) {
                String sfFilename = link.ContentDocument.Title;
                if(String.isNotBlank(link.ContentDocument.FileExtension)) {
                    sfFilename += '.' + link.ContentDocument.FileExtension;
                }
                
                if(sfFilename == deletedFilename) {
                    docIdToDelete = link.ContentDocumentId;
                    break;
                }
            }
            
            if(docIdToDelete != null) {
                // Delete ContentDocument (this cascades to ContentDocumentLink)
                delete new ContentDocument(Id = docIdToDelete);
                System.debug('Deleted file from Salesforce: ' + deletedFilename);
                
                res.statusCode = 200;
                return new WebhookResponse(true, 'File deleted: ' + deletedFilename);
            } else {
                System.debug('File not found in Salesforce: ' + deletedFilename);
                res.statusCode = 200;
                return new WebhookResponse(true, 'File not found in SF: ' + deletedFilename);
            }
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error deleting attachment: ' + e.getMessage());
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }
    
    /**
     * FIXED: Improved Case lookup with better error handling
     */
    private static Case findCaseByJiraKey(String jiraKey) {
        // Clean the Jira key
        String cleanJiraKey = jiraKey != null ? jiraKey.trim() : '';
        
        System.debug('=== CASE LOOKUP DEBUG ===');
        System.debug('Searching for Jira Key: "' + cleanJiraKey + '"');
        System.debug('Length: ' + cleanJiraKey.length() + ' characters');
        
        // Try exact match first
        List<Case> cases = [
            SELECT Id, CaseNumber, Jira_Issue_Key__c
            FROM Case 
            WHERE Jira_Issue_Key__c = :cleanJiraKey
            LIMIT 1
        ];
        
        System.debug('Exact match query returned: ' + cases.size() + ' cases');
        
        if(!cases.isEmpty()) {
            System.debug('✓ Found Case: ' + cases[0].CaseNumber);
            return cases[0];
        }
        
        // If no exact match, try case-insensitive search
        System.debug('Trying case-insensitive search...');
        
        List<Case> allCasesWithJiraKey = [
            SELECT Id, CaseNumber, Jira_Issue_Key__c
            FROM Case 
            WHERE Jira_Issue_Key__c != null
            LIMIT 100
        ];
        
        System.debug('Found ' + allCasesWithJiraKey.size() + ' cases with Jira keys:');
        
        for(Case c : allCasesWithJiraKey) {
            String existingKey = c.Jira_Issue_Key__c != null ? c.Jira_Issue_Key__c.trim() : '';
            System.debug('  - Case ' + c.CaseNumber + ': "' + existingKey + '" (Length: ' + existingKey.length() + ')');
            
            // Try case-insensitive match
            if(existingKey.equalsIgnoreCase(cleanJiraKey)) {
                System.debug('✓ Found case-insensitive match!');
                return c;
            }
        }
        
        System.debug('✗ NO MATCH FOUND');
        return null;
    }
    
    /**
     * Helper: Debug what Cases exist in Salesforce
     */
    private static void debugExistingCases() {
        List<Case> recentCases = [
            SELECT Id, CaseNumber, Jira_Issue_Key__c, Status, CreatedDate
            FROM Case 
            WHERE Jira_Issue_Key__c != null
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
        
        System.debug('=== RECENT CASES WITH JIRA KEYS ===');
        for(Case c : recentCases) {
            System.debug('Case ' + c.CaseNumber + ': Jira Key = "' + c.Jira_Issue_Key__c + '"');
        }
    }
    
    /**
     * Handles comment deletion from Jira
     */
    private static WebhookResponse handleCommentDeleted(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) {
            throw new WebhookException('Missing issue data');
        }
        String jiraKey = (String) issue.get('key');
        
        Map<String, Object> comment = (Map<String, Object>) payload.get('comment');
        if(comment == null) {
            throw new WebhookException('Missing comment data');
        }
        
        String commentId = (String) comment.get('id');
        
        System.debug('Processing deleted comment from Jira: ' + jiraKey + ' (Comment ID: ' + commentId + ')');
        
        String result = JiraWebhookService.deleteCaseComment(jiraKey, commentId);
        
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    /**
     * Handles new comment creation
     */
    private static WebhookResponse handleCommentCreated(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) {
            throw new WebhookException('Missing issue data');
        }
        String jiraKey = (String) issue.get('key');
        
        Map<String, Object> comment = (Map<String, Object>) payload.get('comment');
        if(comment == null) {
            throw new WebhookException('Missing comment data');
        }
        
        String commentId = (String) comment.get('id');
        
        Map<String, Object> author = (Map<String, Object>) comment.get('author');
        String authorName = author != null ? (String) author.get('displayName') : 'Jira User';
        
        String commentText = extractCommentText(comment);
        
        if(String.isBlank(commentText)) {
            return new WebhookResponse(true, 'Empty comment');
        }
        
        System.debug('Processing new comment from Jira: ' + jiraKey + ' by ' + authorName);
        
        String result = JiraWebhookService.addCommentToCase(jiraKey, commentId, commentText, authorName);
        
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    /**
     * Handles comment updates/edits
     */
    private static WebhookResponse handleCommentUpdated(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) {
            throw new WebhookException('Missing issue data');
        }
        String jiraKey = (String) issue.get('key');
        
        Map<String, Object> comment = (Map<String, Object>) payload.get('comment');
        if(comment == null) {
            throw new WebhookException('Missing comment data');
        }
        
        String commentId = (String) comment.get('id');
        
        Map<String, Object> updateAuthor = (Map<String, Object>) comment.get('updateAuthor');
        String authorName = updateAuthor != null ? (String) updateAuthor.get('displayName') : 'Jira User';
        
        String commentText = extractCommentText(comment);
        
        if(String.isBlank(commentText)) {
            return new WebhookResponse(true, 'Empty comment');
        }
        
        System.debug('Processing updated comment from Jira: ' + jiraKey + ' (ID: ' + commentId + ')');
        
        String result = JiraWebhookService.updateCaseComment(jiraKey, commentId, commentText, authorName);
        
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    /**
     * Extracts comment text - handles both plain text and ADF format
     */
    private static String extractCommentText(Map<String, Object> comment) {
        Object bodyObj = comment.get('body');
        
        if(bodyObj == null) {
            return '';
        }
        
        if(bodyObj instanceof String) {
            return (String) bodyObj;
        }
        
        if(bodyObj instanceof Map<String, Object>) {
            return extractTextFromADF((Map<String, Object>) bodyObj);
        }
        
        return '';
    }
    
    /**
     * Extracts plain text from Atlassian Document Format
     */
    private static String extractTextFromADF(Map<String, Object> adfBody) {
        if(adfBody == null) {
            return '';
        }
        
        List<String> textParts = new List<String>();
        List<Object> content = (List<Object>) adfBody.get('content');
        
        if(content == null || content.isEmpty()) {
            return '';
        }
        
        for(Object contentItem : content) {
            Map<String, Object> contentNode = (Map<String, Object>) contentItem;
            String nodeType = (String) contentNode.get('type');
            
            if(nodeType == 'paragraph' || nodeType == 'heading') {
                List<Object> paragraphContent = (List<Object>) contentNode.get('content');
                if(paragraphContent != null) {
                    for(Object textItem : paragraphContent) {
                        Map<String, Object> textNode = (Map<String, Object>) textItem;
                        if(textNode.get('type') == 'text') {
                            String text = (String) textNode.get('text');
                            if(!String.isBlank(text)) {
                                textParts.add(text);
                            }
                        }
                    }
                }
            }
        }
        
        return String.join(textParts, '\n');
    }
    
    /**
     * Gets the newly added attachment ID from changelog
     */
    private static String getNewAttachmentId(Map<String, Object> payload) {
        Map<String, Object> changelog = (Map<String, Object>) payload.get('changelog');
        if(changelog == null) return null;
        
        List<Object> items = (List<Object>) changelog.get('items');
        if(items == null) return null;
        
        for(Object itemObj : items) {
            Map<String, Object> item = (Map<String, Object>) itemObj;
            if(item.get('field') == 'Attachment' || item.get('field') == 'attachment') {
                return (String) item.get('to');
            }
        }
        
        return null;
    }
    
    /**
     * Gets deleted filename from changelog
     */
    private static String getDeletedFilename(Map<String, Object> payload) {
        Map<String, Object> changelog = (Map<String, Object>) payload.get('changelog');
        if(changelog == null) return null;
        
        List<Object> items = (List<Object>) changelog.get('items');
        if(items == null) return null;
        
        for(Object itemObj : items) {
            Map<String, Object> item = (Map<String, Object>) itemObj;
            if(item.get('field') == 'Attachment' || item.get('field') == 'attachment') {
                return (String) item.get('fromString');
            }
        }
        
        return null;
    }
    
    /**
     * Checks if attachment was deleted
     */
    private static Boolean isAttachmentDeleted(Map<String, Object> payload) {
        Map<String, Object> changelog = (Map<String, Object>) payload.get('changelog');
        if(changelog == null) return false;
        
        List<Object> items = (List<Object>) changelog.get('items');
        if(items == null) return false;
        
        for(Object itemObj : items) {
            Map<String, Object> item = (Map<String, Object>) itemObj;
            if(item.get('field') == 'Attachment' || item.get('field') == 'attachment') {
                // Deletion: fromString has value, toString is null
                return item.get('fromString') != null && item.get('toString') == null;
            }
        }
        
        return false;
    }
    
    private static Boolean isAttachmentAdded(Map<String, Object> payload) {
        Map<String, Object> changelog = (Map<String, Object>) payload.get('changelog');
        if(changelog == null) return false;
        
        List<Object> items = (List<Object>) changelog.get('items');
        if(items == null) return false;
        
        for(Object itemObj : items) {
            Map<String, Object> item = (Map<String, Object>) itemObj;
            if(item.get('field') == 'Attachment' || item.get('field') == 'attachment') {
                // Addition: fromString is null, toString has value
                return item.get('fromString') == null && item.get('to') != null;
            }
        }
        
        return false;
    }
    
    private static Boolean isStatusChanged(Map<String, Object> payload) {
        Map<String, Object> changelog = (Map<String, Object>) payload.get('changelog');
        if(changelog == null) return false;
        
        List<Object> items = (List<Object>) changelog.get('items');
        if(items == null || items.isEmpty()) return false;
        
        for(Object itemObj : items) {
            Map<String, Object> item = (Map<String, Object>) itemObj;
            if(item.get('field') == 'status') {
                return true;
            }
        }
        return false;
    }
    
    private static Boolean validateAuthentication(RestRequest req) {
        Integration_Config__mdt config = [
            SELECT API_Key__c 
            FROM Integration_Config__mdt 
            WHERE DeveloperName = 'Jira_Webhook_Token' 
            LIMIT 1
        ];
        
        if(config == null || String.isBlank(config.API_Key__c)) {
            System.debug(LoggingLevel.WARN, 'Webhook token not configured');
            return false;
        }
        
        String providedToken = req.headers.get('X-Jira-Webhook-Token');
        if(String.isBlank(providedToken)) {
            providedToken = req.params.get('token');
        }
        
        if(String.isBlank(providedToken)) {
            System.debug(LoggingLevel.WARN, 'No auth token provided');
            return false;
        }
        
        Boolean isValid = providedToken == config.API_Key__c;
        if(!isValid) {
            System.debug(LoggingLevel.ERROR, 'Invalid token');
        }
        
        return isValid;
    }
    
    global class WebhookResponse {
        public Boolean success;
        public String message;
        public Long timestamp;
        
        public WebhookResponse(Boolean success, String message) {
            this.success = success;
            this.message = message;
            this.timestamp = System.now().getTime();
        }
    }
    
    public class WebhookException extends Exception {}
}