/**
 * CaseTrigger - Main trigger for Case object
 * 
 * Purpose: Handles Case escalations to Jira
 * 
 * Important: Includes recursion prevention to avoid loops
 * when Cases are updated by Jira webhooks
 */
trigger CaseTrigger on Case (after update) {
    
    // Recursion prevention flag
    // This prevents the trigger from running when updates come from Jira webhook
    if(CaseTriggerHelper.isExecuting) {
        return;
    }
    
    // Track which cases need escalation
    List<Case> casesToProcess = new List<Case>();
    
    for(Case c : Trigger.new) {
        Case oldCase = Trigger.oldMap.get(c.Id);
        
        // Check if status changed TO "Escalate to Engineering"
        Boolean statusChangedToEscalate = 
            c.Status == 'Escalate to Engineering' && 
            oldCase.Status != 'Escalate to Engineering';
        
        // Check if this is a new status change (not from existing escalation)
        Boolean statusJustChanged = 
            c.Status != oldCase.Status;
        
        // Check if not already processed (prevent duplicate processing)
        Boolean notAlreadyProcessed = 
            String.isBlank(c.Escalation_Status__c) || 
            c.Escalation_Status__c != 'Processing';
        
        // Only process if:
        // 1. Status changed to "Escalate to Engineering"
        // 2. Status actually changed (not just field update)
        // 3. Not already being processed
        // 4. Update was NOT triggered by Jira webhook (checked via Last_Jira_Sync__c)
        Boolean isFromJiraWebhook = c.Last_Jira_Sync__c != oldCase.Last_Jira_Sync__c;
        
        if(statusChangedToEscalate && statusJustChanged && notAlreadyProcessed && !isFromJiraWebhook) {
            casesToProcess.add(c);
        }
    }
    
    // Process escalations
    if(!casesToProcess.isEmpty()) {
        System.debug('Escalating ' + casesToProcess.size() + ' case(s) to engineering');
        
        // Call @future method for each case
        // Future method will handle AI generation and Jira creation
        for(Case caseRecord : casesToProcess) {
            GeminiAIService.getSummaryAndCreateJira(caseRecord.Id);
        }
    }
}

/**
 * CaseTriggerHelper - Helper class with recursion prevention
 * 
 * This static variable prevents infinite loops when Jira webhook
 * updates Cases, which would otherwise re-trigger the escalation logic
 */