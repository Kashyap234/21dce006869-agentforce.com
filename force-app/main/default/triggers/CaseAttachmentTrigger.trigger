/**
 * CaseAttachmentTrigger - FIXED VERSION
 * 
 * Syncs file attachments between Salesforce and Jira
 * - After Insert: Upload new files to Jira
 * - After Delete: Delete files from Jira
 * 
 * @author Your Name
 * @date 2024
 */
trigger CaseAttachmentTrigger on ContentDocumentLink (after insert, after delete) {
    
    if(Trigger.isAfter && Trigger.isInsert) {
        CaseAttachmentTriggerHandler.handleInsert(Trigger.new);
    }
    
    if(Trigger.isAfter && Trigger.isDelete) {
        CaseAttachmentTriggerHandler.handleDelete(Trigger.old);
    }
}