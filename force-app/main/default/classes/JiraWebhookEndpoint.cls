/**
 * JiraWebhookEndpoint - FIXED for Guest User File Deletion
 * * Key Fix:
 * 1. Added fallback query to ContentVersion in deleteFileFromSalesforce
 * (Fixes "No files found" error for Guest Users)
 * * @author Your Name
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
            else if(webhookEvent == 'attachment_deleted') {
                return handleDirectAttachmentDeleted(payload, res);
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
     * Handles direct attachment_deleted events
     */
    private static WebhookResponse handleDirectAttachmentDeleted(Map<String, Object> payload, RestResponse res) {
        try {
            System.debug('=== PROCESSING DIRECT ATTACHMENT DELETION ===');
            
            // Get attachment info from payload
            Map<String, Object> attachment = (Map<String, Object>) payload.get('attachment');
            if(attachment == null) {
                return new WebhookResponse(true, 'No attachment data found');
            }
            
            String filename = (String) attachment.get('filename');
            String attachmentId = (String) attachment.get('id');
            
            System.debug('Deleting file: ' + filename + ' (ID: ' + attachmentId + ')');
            
            // Get issue info
            // NOTE: 'attachment_deleted' payload sometimes omits 'issue'. 
            // If missing, we cannot proceed here. The 'jira:issue_updated' handler will catch it via changelog.
            Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
            if(issue == null) {
                String msg = 'No issue data in attachment_deleted payload. Skipping (will rely on changelog).';
                System.debug(LoggingLevel.WARN, msg);
                return new WebhookResponse(true, msg);
            }
            
            String jiraKey = (String) issue.get('key');
            System.debug('From Jira issue: ' + jiraKey);
            
            // Find the Case
            Case targetCase = findCaseByJiraKey(jiraKey);
            
            if(targetCase == null) {
                String msg = 'No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.WARN, msg);
                res.statusCode = 200;
                return new WebhookResponse(true, msg);
            }
            
            System.debug('✓ Found Case: ' + targetCase.CaseNumber);
            
            // Delete the file from Salesforce
            Boolean deleted = deleteFileFromSalesforce(targetCase.Id, filename);
            
            if(deleted) {
                res.statusCode = 200;
                return new WebhookResponse(true, 'File deleted: ' + filename);
            } else {
                res.statusCode = 200;
                return new WebhookResponse(true, 'File not found in SF: ' + filename);
            }
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error in direct attachment deletion: ' + e.getMessage());
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }
    
    /**
     * Handles issue updates (status changes, attachments from changelog)
     */
    private static WebhookResponse handleIssueUpdated(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) {
            throw new WebhookException('Missing issue data');
        }
        
        String jiraKey = (String) issue.get('key');
        
        // Check for attachment changes in changelog
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
     * IMPROVED: Delete file from Salesforce with better matching & Guest User Fallback
     */
    private static Boolean deleteFileFromSalesforce(Id caseId, String jiraFilename) {
        System.debug('=== FILE DELETION DEBUG ===');
        System.debug('Looking for file: "' + jiraFilename + '"');
        System.debug('On Case: ' + caseId);
        
        // Map of DocumentId => Filename (normalized)
        Map<Id, String> candidateFiles = new Map<Id, String>();

        // 1. Try standard ContentDocumentLink query
        List<ContentDocumentLink> allLinks = [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
        ];
        
        System.debug('Found ' + allLinks.size() + ' files via ContentDocumentLink');

        for(ContentDocumentLink link : allLinks) {
            String name = link.ContentDocument.Title;
            // Append extension if not already present in title
            if(String.isNotBlank(link.ContentDocument.FileExtension) && !name.endsWithIgnoreCase('.' + link.ContentDocument.FileExtension)) {
                name += '.' + link.ContentDocument.FileExtension;
            }
            candidateFiles.put(link.ContentDocumentId, name);
        }
        
        // 2. Fallback: Query ContentVersion directly (Fix for Guest Users)
        // Guest users sometimes can't query ContentDocumentLink but can see ContentVersion they created or via FirstPublishLocationId
        if(candidateFiles.isEmpty()) {
            System.debug('⚠️ No files found via Links. Attempting ContentVersion fallback...');
            List<ContentVersion> versions = [
                SELECT ContentDocumentId, Title, FileExtension 
                FROM ContentVersion 
                WHERE FirstPublishLocationId = :caseId
                AND IsLatest = true
            ];
            System.debug('Found ' + versions.size() + ' files via ContentVersion');
            
            for(ContentVersion cv : versions) {
                String name = cv.Title;
                if(String.isNotBlank(cv.FileExtension) && !name.endsWithIgnoreCase('.' + cv.FileExtension)) {
                    name += '.' + cv.FileExtension;
                }
                candidateFiles.put(cv.ContentDocumentId, name);
            }
        }
        
        if(candidateFiles.isEmpty()) {
            System.debug('❌ No matching files found on Case (after fallback)');
            return false;
        }

        // 3. Match filename
        Id docIdToDelete = null;
        for(Id docId : candidateFiles.keySet()) {
            String sfFilename = candidateFiles.get(docId);
            
            System.debug('Checking: ' + sfFilename);
            
            // Exact match
            if(sfFilename.equalsIgnoreCase(jiraFilename)) {
                docIdToDelete = docId;
                System.debug('✓ MATCH FOUND: ' + docId);
                break;
            }
            // Try title-only match (if Jira sent filename without extension but SF has it)
            // Or if Jira sent filename WITH extension but SF title is just the name
            // (Note: The normalization above handles most extension cases)
        }
        
        if(docIdToDelete != null) {
            try {
                // CRITICAL: Set flag to prevent trigger from firing
                CaseTriggerHelper.isExecuting = true;
                
                // Delete ContentDocument
                delete new ContentDocument(Id = docIdToDelete);
                
                System.debug('✓ Successfully deleted ContentDocument: ' + docIdToDelete);
                return true;
                
            } catch(Exception e) {
                System.debug(LoggingLevel.ERROR, 'Failed to delete file: ' + e.getMessage());
                return false;
            } finally {
                CaseTriggerHelper.isExecuting = false;
            }
        } else {
            System.debug('❌ Filename not found among candidates');
            return false;
        }
    }
    
    /**
     * Handles attachment additions from Jira
     */
    private static WebhookResponse handleAttachmentAdded(Map<String, Object> payload, String jiraKey, RestResponse res) {
        System.debug('Processing attachment addition for: ' + jiraKey);
        
        try {
            Case targetCase = findCaseByJiraKey(jiraKey);
            
            if(targetCase == null) {
                String msg = 'ERROR: No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.ERROR, msg);
                res.statusCode = 200;
                return new WebhookResponse(false, msg);
            }
            
            System.debug('✓ Found Case: ' + targetCase.CaseNumber + ' (ID: ' + targetCase.Id + ')');
            
            Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
            Map<String, Object> fields = (Map<String, Object>) issue.get('fields');
            List<Object> attachments = (List<Object>) fields.get('attachment');
            
            if(attachments == null || attachments.isEmpty()) {
                return new WebhookResponse(true, 'No attachments in payload');
            }
            
            String newAttachmentId = getNewAttachmentId(payload);
            
            if(String.isBlank(newAttachmentId)) {
                return new WebhookResponse(true, 'Could not identify new attachment');
            }
            
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
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }

    /**
     * Handles direct attachment_created events
     */
    private static WebhookResponse handleDirectAttachmentEvent(Map<String, Object> payload, RestResponse res) {
        try {
            if (!payload.containsKey('issue') || payload.get('issue') == null) {
                String msg = 'Skipping attachment_created event: Payload missing "issue" object.';
                System.debug(LoggingLevel.WARN, msg);
                res.statusCode = 200;
                return new WebhookResponse(true, msg);
            }

            Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
            String jiraKey = (String) issue.get('key');
            
            System.debug('Processing direct attachment event for: ' + jiraKey);
    
            Case targetCase = findCaseByJiraKey(jiraKey);
            if(targetCase == null) {
                String msg = 'ERROR: No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.ERROR, msg);
                res.statusCode = 200; 
                return new WebhookResponse(false, msg);
            }
    
            Map<String, Object> attachment = (Map<String, Object>) payload.get('attachment');
            if (attachment == null) {
                 return new WebhookResponse(true, 'No attachment data found');
            }
    
            String attachmentId = (String) attachment.get('id');
            String filename = (String) attachment.get('filename');
            String contentUrl = (String) attachment.get('content');
    
            System.debug('Queueing sync for: ' + filename + ' (ID: ' + attachmentId + ')');
    
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
            res.statusCode = 500;
            return new WebhookResponse(false, 'Error: ' + e.getMessage());
        }
    }
    
    /**
     * Handles attachment deletions from changelog (legacy)
     */
    private static WebhookResponse handleAttachmentDeleted(Map<String, Object> payload, String jiraKey, RestResponse res) {
        System.debug('Processing attachment deletion (changelog) for: ' + jiraKey);
        
        try {
            Case targetCase = findCaseByJiraKey(jiraKey);
            
            if(targetCase == null) {
                String msg = 'No Case found with Jira Key: ' + jiraKey;
                System.debug(LoggingLevel.WARN, msg);
                res.statusCode = 200;
                return new WebhookResponse(true, msg);
            }
            
            String deletedFilename = getDeletedFilename(payload);
            
            if(String.isBlank(deletedFilename)) {
                return new WebhookResponse(true, 'Could not identify deleted filename');
            }
            
            System.debug('Deleted filename from changelog: ' + deletedFilename);
            
            Boolean deleted = deleteFileFromSalesforce(targetCase.Id, deletedFilename);
            
            if(deleted) {
                res.statusCode = 200;
                return new WebhookResponse(true, 'File deleted: ' + deletedFilename);
            } else {
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
     * Case lookup with improved debugging
     */
    private static Case findCaseByJiraKey(String jiraKey) {
        String cleanJiraKey = jiraKey != null ? jiraKey.trim() : '';
        
        System.debug('=== CASE LOOKUP DEBUG ===');
        System.debug('Searching for Jira Key: "' + cleanJiraKey + '"');
        
        List<Case> cases = [
            SELECT Id, CaseNumber, Jira_Issue_Key__c
            FROM Case 
            WHERE Jira_Issue_Key__c = :cleanJiraKey
            LIMIT 1
        ];
        
        if(!cases.isEmpty()) {
            System.debug('✓ Found Case: ' + cases[0].CaseNumber);
            return cases[0];
        }
        
        System.debug('✗ NO MATCH FOUND');
        return null;
    }
    
    // Comment handlers
    private static WebhookResponse handleCommentDeleted(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) throw new WebhookException('Missing issue data');
        
        String jiraKey = (String) issue.get('key');
        Map<String, Object> comment = (Map<String, Object>) payload.get('comment');
        if(comment == null) throw new WebhookException('Missing comment data');
        
        String commentId = (String) comment.get('id');
        String result = JiraWebhookService.deleteCaseComment(jiraKey, commentId);
        
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    private static WebhookResponse handleCommentCreated(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) throw new WebhookException('Missing issue data');
        
        String jiraKey = (String) issue.get('key');
        Map<String, Object> comment = (Map<String, Object>) payload.get('comment');
        if(comment == null) throw new WebhookException('Missing comment data');
        
        String commentId = (String) comment.get('id');
        Map<String, Object> author = (Map<String, Object>) comment.get('author');
        String authorName = author != null ? (String) author.get('displayName') : 'Jira User';
        String commentText = extractCommentText(comment);
        
        if(String.isBlank(commentText)) {
            return new WebhookResponse(true, 'Empty comment');
        }
        
        String result = JiraWebhookService.addCommentToCase(jiraKey, commentId, commentText, authorName);
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    private static WebhookResponse handleCommentUpdated(Map<String, Object> payload, RestResponse res) {
        Map<String, Object> issue = (Map<String, Object>) payload.get('issue');
        if(issue == null) throw new WebhookException('Missing issue data');
        
        String jiraKey = (String) issue.get('key');
        Map<String, Object> comment = (Map<String, Object>) payload.get('comment');
        if(comment == null) throw new WebhookException('Missing comment data');
        
        String commentId = (String) comment.get('id');
        Map<String, Object> updateAuthor = (Map<String, Object>) comment.get('updateAuthor');
        String authorName = updateAuthor != null ? (String) updateAuthor.get('displayName') : 'Jira User';
        String commentText = extractCommentText(comment);
        
        if(String.isBlank(commentText)) {
            return new WebhookResponse(true, 'Empty comment');
        }
        
        String result = JiraWebhookService.updateCaseComment(jiraKey, commentId, commentText, authorName);
        res.statusCode = 200;
        return new WebhookResponse(true, result);
    }
    
    private static String extractCommentText(Map<String, Object> comment) {
        Object bodyObj = comment.get('body');
        if(bodyObj == null) return '';
        if(bodyObj instanceof String) return (String) bodyObj;
        if(bodyObj instanceof Map<String, Object>) {
            return extractTextFromADF((Map<String, Object>) bodyObj);
        }
        return '';
    }
    
    private static String extractTextFromADF(Map<String, Object> adfBody) {
        if(adfBody == null) return '';
        
        List<String> textParts = new List<String>();
        List<Object> content = (List<Object>) adfBody.get('content');
        
        if(content == null || content.isEmpty()) return '';
        
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
    
    public static void deleteFileSystemMode(String caseId, String jiraFilename) {
        System.debug('Executing System Mode Deletion for: ' + jiraFilename);
        
        List<ContentDocumentLink> allLinks = [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
        ];
        
        Id docIdToDelete = null;
        
        for(ContentDocumentLink link : allLinks) {
            String sfTitle = link.ContentDocument.Title;
            String sfExtension = link.ContentDocument.FileExtension;
            String sfFullFilename = sfTitle;
            
            // Reconstruct full filename
            if(String.isNotBlank(sfExtension) && !sfTitle.endsWithIgnoreCase('.' + sfExtension)) {
                sfFullFilename += '.' + sfExtension;
            }
            
            // Match (Exact or Title-only)
            if(sfFullFilename.equalsIgnoreCase(jiraFilename) || sfTitle.equalsIgnoreCase(jiraFilename)) {
                docIdToDelete = link.ContentDocumentId;
                break;
            }
        }
        
        if(docIdToDelete != null) {
            try {
                // Prevent recursion
                CaseTriggerHelper.isExecuting = true;
                delete new ContentDocument(Id = docIdToDelete);
                System.debug('Successfully deleted file: ' + docIdToDelete);
            } catch(Exception e) {
                System.debug(LoggingLevel.ERROR, 'System Mode Delete Failed: ' + e.getMessage());
            } finally {
                CaseTriggerHelper.isExecuting = false;
            }
        } else {
            System.debug('File not found in System Mode query: ' + jiraFilename);
        }
    }

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
    
    private static Boolean isAttachmentDeleted(Map<String, Object> payload) {
        Map<String, Object> changelog = (Map<String, Object>) payload.get('changelog');
        if(changelog == null) return false;
        
        List<Object> items = (List<Object>) changelog.get('items');
        if(items == null) return false;
        
        for(Object itemObj : items) {
            Map<String, Object> item = (Map<String, Object>) itemObj;
            if(item.get('field') == 'Attachment' || item.get('field') == 'attachment') {
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
            if(item.get('field') == 'status') return true;
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