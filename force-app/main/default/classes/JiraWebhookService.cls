/**
 * JiraWebhookService - Enhanced with Comment Tracking
 * 
 * Uses Case_Comment_Jira_Sync__c object for tracking
 * 
 * @author Your Name
 * @date 2024
 */
public without sharing class JiraWebhookService {
    
    /**
     * Updates Case status from Jira
     */
    public static String updateCaseFromJira(String jiraKey, String jiraStatus) {
        List<Case> cases = [
            SELECT Id, CaseNumber, Status, Jira_Issue_Key__c, Jira_Status__c
            FROM Case 
            WHERE Jira_Issue_Key__c = :jiraKey 
            LIMIT 1
        ];
        
        if(cases.isEmpty()) {
            String msg = 'No Case found with Jira Key: ' + jiraKey;
            System.debug(LoggingLevel.WARN, msg);
            return msg;
        }
        
        Case caseRecord = cases[0];
        
        if(caseRecord.Jira_Status__c == jiraStatus) {
            String msg = 'Case already has Jira status: ' + jiraStatus;
            System.debug(msg);
            return msg;
        }
        
        String salesforceStatus = mapJiraToSalesforceStatus(jiraStatus);
        if(String.isBlank(salesforceStatus)) {
            salesforceStatus = caseRecord.Status;
        }
        
        String oldStatus = caseRecord.Status;
        caseRecord.Status = salesforceStatus;
        caseRecord.Jira_Status__c = jiraStatus;
        caseRecord.Last_Jira_Sync__c = System.now();
        
        CaseTriggerHelper.isExecuting = true;
        try {
            Database.update(caseRecord);
        } finally {
            CaseTriggerHelper.isExecuting = false;
        }
        
        String msg = String.format(
            'Updated Case {0}: {1} → {2} (Jira: {3})',
            new List<String>{caseRecord.CaseNumber, oldStatus, salesforceStatus, jiraStatus}
        );
        System.debug(msg);
        
        logSync(caseRecord.Id, jiraKey, oldStatus, salesforceStatus, jiraStatus);
        return msg;
    }
    
    /**
     * Adds a Jira comment to Salesforce Case
     * 
     * Uses Case_Comment_Jira_Sync__c for tracking
     */
    // public static String addCommentToCase(String jiraKey, String commentId, String commentText, String authorName) {
    //     List<Case> cases = [
    //         SELECT Id, CaseNumber
    //         FROM Case 
    //         WHERE Jira_Issue_Key__c = :jiraKey 
    //         LIMIT 1
    //     ];
        
    //     if(cases.isEmpty()) {
    //         String msg = 'No Case found with Jira Key: ' + jiraKey;
    //         System.debug(LoggingLevel.WARN, msg);
    //         return msg;
    //     }
        
    //     Case caseRecord = cases[0];
        
    //     // Check if comment already exists (prevent duplicates)
    //     List<Case_Comment_Jira_Sync__c> existingSyncs = [
    //         SELECT Id, Case_Comment_ID__c
    //         FROM Case_Comment_Jira_Sync__c 
    //         WHERE Jira_Comment_ID__c = :commentId
    //         AND Jira_Issue_Key__c = :jiraKey
    //         LIMIT 1
    //     ];
        
    //     if(!existingSyncs.isEmpty()) {
    //         String msg = 'Comment already synced: ' + commentId;
    //         System.debug(msg);
    //         return msg;
    //     }
        
    //     // Format comment with attribution
    //     String formattedComment = '--- Comment from Jira ---\n';
    //     formattedComment += 'Author: ' + authorName + '\n';
    //     formattedComment += 'Jira Issue: ' + jiraKey + '\n';
    //     formattedComment += 'Comment ID: ' + commentId + '\n\n';
    //     formattedComment += commentText;
        
    //     // Create CaseComment
    //     CaseComment newComment = new CaseComment(
    //         ParentId = caseRecord.Id,
    //         CommentBody = formattedComment,
    //         IsPublished = false
    //     );
        
    //     try {
    //         insert newComment;
            
    //         // Create sync tracking record
    //         Case_Comment_Jira_Sync__c syncRecord = new Case_Comment_Jira_Sync__c(
    //             Case_Comment_ID__c = newComment.Id,
    //             Jira_Comment_ID__c = commentId,
    //             Jira_Issue_Key__c = jiraKey,
    //             Last_Synced__c = System.now()
    //         );
    //         insert syncRecord;
            
    //         String msg = 'Added comment from Jira to Case ' + caseRecord.CaseNumber;
    //         System.debug(msg);
    //         return msg;
            
    //     } catch(DmlException e) {
    //         String error = 'Failed to add comment: ' + e.getMessage();
    //         System.debug(LoggingLevel.ERROR, error);
    //         throw new JiraWebhookException(error);
    //     }
    // }
    /**
     * Adds a Jira comment to Salesforce Case
     * * Uses Case_Comment_Jira_Sync__c for tracking
     */
    public static String addCommentToCase(String jiraKey, String commentId, String commentText, String authorName) {
        
        // --- FIX START: PREVENT ECHO ---
        // Check if this comment actually originated from Salesforce
        // In JiraService.cls, we prepend "Comment from Salesforce by..."
        // If we see that here, it means the webhook is echoing our own message back.
        // if (commentText != null && commentText.startsWith('Comment from Salesforce by')) {
        //     String msg = 'Ignored echo comment from Salesforce (ID: ' + commentId + ')';
        //     System.debug(msg);
        //     return msg;
        // }
        // --- FIX END ---

        List<Case> cases = [
            SELECT Id, CaseNumber
            FROM Case 
            WHERE Jira_Issue_Key__c = :jiraKey 
            LIMIT 1
        ];
        
        if(cases.isEmpty()) {
            String msg = 'No Case found with Jira Key: ' + jiraKey;
            System.debug(LoggingLevel.WARN, msg);
            return msg;
        }
        
        Case caseRecord = cases[0];
        
        // Check if comment already exists (prevent duplicates)
        List<Case_Comment_Jira_Sync__c> existingSyncs = [
            SELECT Id, Case_Comment_ID__c
            FROM Case_Comment_Jira_Sync__c 
            WHERE Jira_Comment_ID__c = :commentId
            AND Jira_Issue_Key__c = :jiraKey
            LIMIT 1
        ];
        
        if(!existingSyncs.isEmpty()) {
            String msg = 'Comment already synced: ' + commentId;
            System.debug(msg);
            return msg;
        }
        
        // Format comment with attribution
        String formattedComment = '--- Comment from Jira ---\n';
        formattedComment += 'Author: ' + authorName + '\n';
        formattedComment += 'Jira Issue: ' + jiraKey + '\n';
        formattedComment += 'Comment ID: ' + commentId + '\n\n';
        formattedComment += commentText;
        
        // Create CaseComment
        CaseComment newComment = new CaseComment(
            ParentId = caseRecord.Id,
            CommentBody = formattedComment,
            IsPublished = false
        );
        
        try {
            insert newComment;
            
            // Create sync tracking record
            Case_Comment_Jira_Sync__c syncRecord = new Case_Comment_Jira_Sync__c(
                Case_Comment_ID__c = newComment.Id,
                Jira_Comment_ID__c = commentId,
                Jira_Issue_Key__c = jiraKey,
                Last_Synced__c = System.now()
            );
            insert syncRecord;
            
            String msg = 'Added comment from Jira to Case ' + caseRecord.CaseNumber;
            System.debug(msg);
            return msg;
            
        } catch(DmlException e) {
            String error = 'Failed to add comment: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, error);
            throw new JiraWebhookException(error);
        }
    }
    
    /**
     * Updates an existing Salesforce CaseComment from Jira
     */
    public static String updateCaseComment(String jiraKey, String commentId, String commentText, String authorName) {
        List<Case> cases = [
            SELECT Id, CaseNumber
            FROM Case 
            WHERE Jira_Issue_Key__c = :jiraKey 
            LIMIT 1
        ];
        
        if(cases.isEmpty()) {
            String msg = 'No Case found with Jira Key: ' + jiraKey;
            System.debug(LoggingLevel.WARN, msg);
            return msg;
        }
        
        Case caseRecord = cases[0];
        
        // Find existing comment by Jira Comment ID via sync record
        List<Case_Comment_Jira_Sync__c> existingSyncs = [
            SELECT Id, Case_Comment_ID__c
            FROM Case_Comment_Jira_Sync__c 
            WHERE Jira_Comment_ID__c = :commentId
            AND Jira_Issue_Key__c = :jiraKey
            LIMIT 1
        ];
        
        if(existingSyncs.isEmpty()) {
            // Comment doesn't exist yet, create it
            return addCommentToCase(jiraKey, commentId, commentText, authorName);
        }
        
        // Get the CaseComment
        Id caseCommentId = existingSyncs[0].Case_Comment_ID__c;
        List<CaseComment> comments = [
            SELECT Id, CommentBody 
            FROM CaseComment 
            WHERE Id = :caseCommentId 
            LIMIT 1
        ];
        
        if(comments.isEmpty()) {
            // CaseComment was deleted, create new one
            return addCommentToCase(jiraKey, commentId, commentText, authorName);
        }
        
        CaseComment commentToUpdate = comments[0];
        
        // Format updated comment
        String formattedComment = '--- Comment from Jira (UPDATED) ---\n';
        formattedComment += 'Author: ' + authorName + '\n';
        formattedComment += 'Jira Issue: ' + jiraKey + '\n';
        formattedComment += 'Comment ID: ' + commentId + '\n';
        formattedComment += 'Last Updated: ' + System.now().format('yyyy-MM-dd HH:mm:ss') + '\n\n';
        formattedComment += commentText;
        
        commentToUpdate.CommentBody = formattedComment;
        
        try {
            update commentToUpdate;
            
            // Update sync record timestamp
            Case_Comment_Jira_Sync__c syncRecord = existingSyncs[0];
            syncRecord.Last_Synced__c = System.now();
            update syncRecord;
            
            String msg = 'Updated comment in Case ' + caseRecord.CaseNumber;
            System.debug(msg);
            return msg;
            
        } catch(DmlException e) {
            String error = 'Failed to update comment: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, error);
            throw new JiraWebhookException(error);
        }
    }

    /**
     * Add this method to JiraWebhookService class
     * 
     * Deletes a Salesforce CaseComment when it's deleted in Jira
     */
    public static String deleteCaseComment(String jiraKey, String jiraCommentId) {
        List<Case> cases = [
            SELECT Id, CaseNumber
            FROM Case 
            WHERE Jira_Issue_Key__c = :jiraKey 
            LIMIT 1
        ];
        
        if(cases.isEmpty()) {
            String msg = 'No Case found with Jira Key: ' + jiraKey;
            System.debug(LoggingLevel.WARN, msg);
            return msg;
        }
        
        Case caseRecord = cases[0];
        
        // Find the sync record
        List<Case_Comment_Jira_Sync__c> existingSyncs = [
            SELECT Id, Case_Comment_ID__c
            FROM Case_Comment_Jira_Sync__c 
            WHERE Jira_Comment_ID__c = :jiraCommentId
            AND Jira_Issue_Key__c = :jiraKey
            LIMIT 1
        ];
        
        if(existingSyncs.isEmpty()) {
            String msg = 'Comment sync record not found: ' + jiraCommentId;
            System.debug(msg);
            return msg;
        }
        
        Id caseCommentId = existingSyncs[0].Case_Comment_ID__c;
        
        // Find the CaseComment
        List<CaseComment> comments = [
            SELECT Id 
            FROM CaseComment 
            WHERE Id = :caseCommentId 
            LIMIT 1
        ];
        
        if(comments.isEmpty()) {
            // Comment already deleted, just cleanup sync record
            delete existingSyncs[0];
            String msg = 'Comment already deleted in Salesforce, cleaned up sync record';
            System.debug(msg);
            return msg;
        }
        
        try {
            // Set flag to prevent recursion
            CaseTriggerHelper.isExecuting = true;
            
            // Delete CaseComment
            delete comments[0];
            
            // Delete sync record
            delete existingSyncs[0];
            
            String msg = 'Deleted comment from Case ' + caseRecord.CaseNumber;
            System.debug(msg);
            return msg;
            
        } catch(DmlException e) {
            String error = 'Failed to delete comment: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, error);
            throw new JiraWebhookException(error);
        } finally {
            CaseTriggerHelper.isExecuting = false;
        }
    }
    
    /**
     * Maps Jira status to Salesforce status
     */
    private static String mapJiraToSalesforceStatus(String jiraStatus) {
        List<Jira_Status_Mapping__mdt> mappings = [
            SELECT Salesforce_Status__c 
            FROM Jira_Status_Mapping__mdt 
            WHERE Jira_Status__c = :jiraStatus 
            LIMIT 1
        ];
        
        if(mappings.isEmpty()) {
            System.debug(LoggingLevel.WARN, 'No mapping for: ' + jiraStatus);
            return null;
        }
        
        String salesforceStatus = mappings[0].Salesforce_Status__c;
        
        if(!isValidCaseStatus(salesforceStatus)) {
            System.debug(LoggingLevel.ERROR, 'Invalid status: ' + salesforceStatus);
            return null;
        }
        
        return salesforceStatus;
    }
    
    /**
     * Validates Case status value
     */
    private static Boolean isValidCaseStatus(String statusValue) {
        if(String.isBlank(statusValue)) return false;
        
        Schema.DescribeFieldResult fieldResult = Case.Status.getDescribe();
        List<Schema.PicklistEntry> picklistValues = fieldResult.getPicklistValues();
        
        for(Schema.PicklistEntry entry : picklistValues) {
            if(entry.getValue() == statusValue) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * Logs sync event
     */
    private static void logSync(Id caseId, String jiraKey, String oldStatus, String newStatus, String jiraStatus) {
        String logMessage = String.format(
            'JIRA SYNC: Case {0} | Jira {1} | {2} → {3} | Jira: {4}',
            new List<String>{caseId, jiraKey, oldStatus, newStatus, jiraStatus}
        );
        System.debug(LoggingLevel.INFO, logMessage);
    }
    
    public class JiraWebhookException extends Exception {}
}