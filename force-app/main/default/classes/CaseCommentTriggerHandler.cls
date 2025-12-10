/**
 * CaseCommentTriggerHandler - ENHANCED with Deletion Support
 * 
 * Handles:
 * 1. New comments with #jira tag
 * 2. Edited comments
 * 3. Deleted comments (syncs deletion to Jira)
 * 
 * @author Your Name
 * @date 2024
 */
public class CaseCommentTriggerHandler {
    
    private static final String JIRA_TAG = '#jira';
    
    /**
     * Handles after insert - NEW comments
     */
    public static void handleAfterInsert(List<CaseComment> newComments) {
        processComments(newComments, null, false);
    }
    
    /**
     * Handles after update - EDITED comments
     */
    public static void handleAfterUpdate(List<CaseComment> newComments, Map<Id, CaseComment> oldCommentsMap) {
        processComments(newComments, oldCommentsMap, true);
    }
    
    /**
     * NEW: Handles after delete - DELETED comments
     */
    public static void handleAfterDelete(List<CaseComment> deletedComments) {
        if(CaseTriggerHelper.isExecuting) {
            System.debug('Recursion detected (Webhook operation), skipping trigger logic.');
            return;
        }
        
        Set<Id> commentIds = new Set<Id>();
        Set<Id> caseIds = new Set<Id>();
        
        for(CaseComment comment : deletedComments) {
            commentIds.add(comment.Id);
            caseIds.add(comment.ParentId);
        }
        
        // Check which comments were synced to Jira
        Map<Id, Case_Comment_Jira_Sync__c> syncRecords = new Map<Id, Case_Comment_Jira_Sync__c>();
        for(Case_Comment_Jira_Sync__c sync : [
            SELECT Case_Comment_ID__c, Jira_Comment_ID__c, Jira_Issue_Key__c
            FROM Case_Comment_Jira_Sync__c 
            WHERE Case_Comment_ID__c IN :commentIds
        ]) {
            syncRecords.put(sync.Case_Comment_ID__c, sync);
        }
        
        // Build list of deletion jobs
        List<CommentDeleteJob> deleteJobs = new List<CommentDeleteJob>();
        
        for(CaseComment comment : deletedComments) {
            Case_Comment_Jira_Sync__c syncRecord = syncRecords.get(comment.Id);
            
            if(syncRecord != null && String.isNotBlank(syncRecord.Jira_Comment_ID__c)) {
                // This comment was synced to Jira, delete it there too
                deleteJobs.add(new CommentDeleteJob(
                    syncRecord.Jira_Issue_Key__c,
                    syncRecord.Jira_Comment_ID__c,
                    comment.Id
                ));
            }
        }
        
        if(!deleteJobs.isEmpty()) {
            System.debug('Queueing deletion of ' + deleteJobs.size() + ' comments in Jira');
            System.enqueueJob(new CommentDeleteQueueable(deleteJobs));
        }
    }
    
    /**
     * Processes comments for sync to Jira (create/update)
     */
    private static void processComments(List<CaseComment> newComments, Map<Id, CaseComment> oldCommentsMap, Boolean isUpdate) {
        
        if(CaseTriggerHelper.isExecuting) {
            System.debug('Recursion detected (Webhook operation), skipping trigger logic.');
            return;
        }

        List<CaseComment> commentsToSync = new List<CaseComment>();
        Set<Id> caseIds = new Set<Id>();
        Set<Id> commentIds = new Set<Id>();
        
        for(CaseComment comment : newComments) {
            commentIds.add(comment.Id);
            caseIds.add(comment.ParentId);
        }
        
        // Check which comments are already synced from Jira
        Map<Id, Case_Comment_Jira_Sync__c> syncRecords = new Map<Id, Case_Comment_Jira_Sync__c>();
        for(Case_Comment_Jira_Sync__c sync : [
            SELECT Case_Comment_ID__c, Jira_Comment_ID__c 
            FROM Case_Comment_Jira_Sync__c 
            WHERE Case_Comment_ID__c IN :commentIds
        ]) {
            syncRecords.put(sync.Case_Comment_ID__c, sync);
        }
        
        for(CaseComment comment : newComments) {
            // Skip if comment originated from Jira (prevent loop)
            Case_Comment_Jira_Sync__c syncRecord = syncRecords.get(comment.Id);
            
            // Check if comment has #jira tag
            if(comment.CommentBody != null && 
               comment.CommentBody.containsIgnoreCase(JIRA_TAG)) {
                
                // For updates, check if body actually changed
                if(isUpdate && oldCommentsMap != null) {
                    CaseComment oldComment = oldCommentsMap.get(comment.Id);
                    if(oldComment.CommentBody == comment.CommentBody) {
                        continue;
                    }
                }
                
                commentsToSync.add(comment);
            }
        }
        
        if(commentsToSync.isEmpty()) {
            System.debug('No comments to sync to Jira');
            return;
        }
        
        System.debug('Found ' + commentsToSync.size() + ' comments to sync to Jira');
        
        // Query Cases to get Jira Issue Keys
        Map<Id, Case> casesMap = new Map<Id, Case>([
            SELECT Id, CaseNumber, Jira_Issue_Key__c
            FROM Case 
            WHERE Id IN :caseIds 
            AND Jira_Issue_Key__c != null
        ]);
        
        // Build list of sync jobs
        List<CommentSyncJob> syncJobs = new List<CommentSyncJob>();
        
        for(CaseComment comment : commentsToSync) {
            Case relatedCase = casesMap.get(comment.ParentId);
            
            if(relatedCase == null) {
                System.debug('Case ' + comment.ParentId + ' has no Jira Issue Key, skipping');
                continue;
            }
            
            // Remove #jira tag from comment
            String cleanComment = comment.CommentBody.replaceAll('(?i)' + JIRA_TAG, '').trim();
            
            syncJobs.add(new CommentSyncJob(
                comment.Id,
                relatedCase.Jira_Issue_Key__c,
                cleanComment,
                comment.CreatedById,
                relatedCase.CaseNumber,
                isUpdate
            ));
        }
        
        if(syncJobs.isEmpty()) {
            System.debug('No valid comments to sync');
            return;
        }
        
        // Queue async job
        System.enqueueJob(new CommentSyncQueueable(syncJobs));
    }
}