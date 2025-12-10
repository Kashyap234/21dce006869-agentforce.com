/**
 * JiraQueueable - Asynchronous Jira issue creation
 * 
 * Purpose: This class allows Jira API callouts to happen after DML operations
 * by running in a separate queueable transaction.
 * 
 * Why Queueable?
 * - Can make HTTP callouts (unlike @future with DML context)
 * - Can chain multiple jobs if needed
 * - Better monitoring and error handling
 * 
 * @author Your Name
 * @date 2024
 */
public class JiraQueueable implements Queueable, Database.AllowsCallouts {
    
    private Id caseId;
    private String aiSummary;
    
    /**
     * Constructor
     * 
     * @param caseId The Salesforce Case Id
     * @param aiSummary The AI-generated bug report
     */
    public JiraQueueable(Id caseId, String aiSummary) {
        this.caseId = caseId;
        this.aiSummary = aiSummary;
    }
    
    /**
     * Execute method - runs asynchronously
     * 
     * This method runs in a separate transaction, allowing HTTP callouts
     * even after the previous transaction had DML operations.
     * 
     * @param context The queueable context
     */
    public void execute(QueueableContext context) {
        System.debug('JiraQueueable executing for Case: ' + this.caseId);
        
        // Call the Jira service to create the issue
        // This now runs in a fresh transaction without pending DML
        JiraService.createJiraIssue(this.caseId, this.aiSummary);
    }
}