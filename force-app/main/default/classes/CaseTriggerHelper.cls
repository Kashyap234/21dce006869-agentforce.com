/**
 * CaseTriggerHelper - Helper class with recursion prevention
 * 
 * This static variable prevents infinite loops when Jira webhook
 * updates Cases, which would otherwise re-trigger the escalation logic
 */
public class CaseTriggerHelper {
    // Static flag to prevent recursion
    // When Jira webhook updates a Case, it sets this to true
    public static Boolean isExecuting = false;
}