/**
 * CaseAttachmentTriggerHandler - Handler for ContentDocumentLink trigger
 * 
 * Handles:
 * 1. New file attachments → Upload to Jira
 * 2. File deletions → Delete from Jira
 * 
 * Key Fix: Only syncs NEWLY ADDED files, not all existing files
 * 
 * @author Your Name
 * @date 2024
 */
public class CaseAttachmentTriggerHandler {
    
    /**
     * Handles new file attachments
     * Only uploads the specific files that were just added
     */
    public static void handleInsert(List<ContentDocumentLink> newLinks) {
        Map<Id, Set<Id>> caseToNewDocIds = new Map<Id, Set<Id>>();
        
        // 1. Group new ContentDocumentIds by Case
        for(ContentDocumentLink link : newLinks) {
            // Check if LinkedEntityId is a Case (Key prefix '500')
            if(String.valueOf(link.LinkedEntityId).startsWith('500')) {
                Id caseId = link.LinkedEntityId;
                
                if(!caseToNewDocIds.containsKey(caseId)) {
                    caseToNewDocIds.put(caseId, new Set<Id>());
                }
                
                // Store the NEW ContentDocumentId
                caseToNewDocIds.get(caseId).add(link.ContentDocumentId);
            }
        }
        
        if(caseToNewDocIds.isEmpty()) return;
        
        // 2. Get Cases with Jira keys
        Map<Id, Case> syncedCases = new Map<Id, Case>([
            SELECT Id, Jira_Issue_Key__c 
            FROM Case 
            WHERE Id IN :caseToNewDocIds.keySet() 
            AND Jira_Issue_Key__c != NULL
        ]);
        
        // 3. Queue upload for ONLY the new files
        for(Id caseId : syncedCases.keySet()) {
            Case c = syncedCases.get(caseId);
            Set<Id> newDocIds = caseToNewDocIds.get(caseId);
            
            System.debug('Queueing upload of ' + newDocIds.size() + ' new files for Case: ' + c.Id);
            
            // Pass the specific ContentDocumentIds that were just added
            System.enqueueJob(new AttachmentUploadQueueable(
                c.Id, 
                c.Jira_Issue_Key__c,
                newDocIds  // CRITICAL: Only new files
            ));
        }
    }
    
    /**
     * Handles file deletions
     * Deletes matching files from Jira
     */
    public static void handleDelete(List<ContentDocumentLink> deletedLinks) {
        Map<Id, List<String>> caseToDeletedFilenames = new Map<Id, List<String>>();
        Set<Id> deletedDocIds = new Set<Id>();
        
        // 1. Collect deleted ContentDocumentIds
        for(ContentDocumentLink link : deletedLinks) {
            if(String.valueOf(link.LinkedEntityId).startsWith('500')) {
                deletedDocIds.add(link.ContentDocumentId);
            }
        }
        
        if(deletedDocIds.isEmpty()) return;
        
        // 2. Get ContentDocument info (filename) before it's fully deleted
        // Note: In after delete, the ContentDocument might still exist
        List<ContentDocument> deletedDocs = [
            SELECT Id, Title, FileExtension
            FROM ContentDocument
            WHERE Id IN :deletedDocIds
        ];
        
        // 3. Build map of Case → deleted filenames
        for(ContentDocumentLink link : deletedLinks) {
            if(String.valueOf(link.LinkedEntityId).startsWith('500')) {
                Id caseId = link.LinkedEntityId;
                
                // Find matching ContentDocument
                for(ContentDocument doc : deletedDocs) {
                    if(doc.Id == link.ContentDocumentId) {
                        String filename = doc.Title;
                        if(String.isNotBlank(doc.FileExtension)) {
                            filename += '.' + doc.FileExtension;
                        }
                        
                        if(!caseToDeletedFilenames.containsKey(caseId)) {
                            caseToDeletedFilenames.put(caseId, new List<String>());
                        }
                        caseToDeletedFilenames.get(caseId).add(filename);
                    }
                }
            }
        }
        
        if(caseToDeletedFilenames.isEmpty()) return;
        
        // 4. Get Cases with Jira keys
        Map<Id, Case> syncedCases = new Map<Id, Case>([
            SELECT Id, Jira_Issue_Key__c 
            FROM Case 
            WHERE Id IN :caseToDeletedFilenames.keySet() 
            AND Jira_Issue_Key__c != NULL
        ]);
        
        // 5. Queue deletion in Jira
        for(Id caseId : syncedCases.keySet()) {
            Case c = syncedCases.get(caseId);
            List<String> filenames = caseToDeletedFilenames.get(caseId);
            
            System.debug('Queueing deletion of ' + filenames.size() + ' files from Jira issue: ' + c.Jira_Issue_Key__c);
            
            System.enqueueJob(new AttachmentDeleteQueueable(
                c.Jira_Issue_Key__c,
                filenames
            ));
        }
    }
}