/**
 * CaseCommentTrigger - ENHANCED with Deletion Support
 * 
 * Trigger Events: After Insert, After Update, After Delete
 * 
 * @author Your Name
 * @date 2024
 */
trigger CaseCommentTrigger on CaseComment (after insert, after update, after delete) {
    
    if(Trigger.isAfter && Trigger.isInsert) {
        CaseCommentTriggerHandler.handleAfterInsert(Trigger.new);
    }
    
    if(Trigger.isAfter && Trigger.isUpdate) {
        CaseCommentTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
    
    if(Trigger.isAfter && Trigger.isDelete) {
        CaseCommentTriggerHandler.handleAfterDelete(Trigger.old);
    }
}