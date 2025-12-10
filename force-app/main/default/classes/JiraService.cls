/**
 * JiraService - Fixed Version with Proper Attachment Handling
 * 
 * Changes:
 * 1. Separated attachment upload into its own Queueable
 * 2. Fixed multipart/form-data boundary handling
 * 
 * @author Your Name
 * @date 2024
 */
public class JiraService {
    
    private static final String JIRA_API_VERSION = '/rest/api/3';
    private static final String JIRA_ISSUE_ENDPOINT = '/issue';
    private static final Integer TIMEOUT_MS = 120000;
    private static final String DEFAULT_ISSUE_TYPE = 'Bug';
    private static final Integer MAX_ATTACHMENTS = 5;
    private static final Integer MAX_FILE_SIZE = 10485760; // 10MB
    
    /**
     * Creates Jira issue (WITHOUT attachments to avoid DML/Callout issue)
     * Attachments will be uploaded separately via AttachmentQueueable
     */
    public static void createJiraIssue(Id caseId, String aiSummary) {
        try {
            Case caseRecord = [
                SELECT CaseNumber, Subject, ContactEmail, Priority
                FROM Case 
                WHERE Id = :caseId 
                LIMIT 1
            ];
            
            Integration_Config__mdt config = [
                SELECT Endpoint__c 
                FROM Integration_Config__mdt 
                WHERE DeveloperName = 'Jira_Project_Key' 
                LIMIT 1
            ];
            
            if(config == null || String.isBlank(config.Endpoint__c)) {
                throw new CalloutException('Jira Project Key not configured');
            }
            
            String jiraProjectKey = config.Endpoint__c;
            Map<String, Object> issueData = buildJiraPayload(jiraProjectKey, caseRecord, aiSummary);
            
            // Create Jira issue
            String jiraKey = callJiraAPI(issueData);
            
            // Update Case with Jira key
            updateCaseWithJiraKey(caseId, jiraKey);
            
            // IMPORTANT: Queue attachment upload AFTER Case update
            // This runs in a separate transaction to avoid DML/Callout conflict
            System.enqueueJob(new AttachmentUploadQueueable(caseId, jiraKey));
            
        } catch(Exception e) {
            handleJiraError(caseId, e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Jira Integration Error: ' + e.getMessage());
        }
    }
    
    /**
     * Adds a comment to an existing Jira issue
     */
    // public static Boolean addCommentToJira(String jiraKey, String commentText, String authorName) {
    //     try {
    //         Map<String, Object> commentPayload = new Map<String, Object>{
    //             'body' => buildCommentADF(commentText, authorName)
    //         };
            
    //         HttpRequest req = new HttpRequest();
    //         req.setEndpoint('callout:Jira_Cloud' + JIRA_API_VERSION + JIRA_ISSUE_ENDPOINT + '/' + jiraKey + '/comment');
    //         req.setMethod('POST');
    //         req.setHeader('Content-Type', 'application/json');
    //         req.setHeader('Accept', 'application/json');
    //         req.setBody(JSON.serialize(commentPayload));
    //         req.setTimeout(TIMEOUT_MS);
            
    //         Http http = new Http();
    //         HttpResponse res = http.send(req);
            
    //         if(res.getStatusCode() == 201) {
    //             System.debug('Successfully added comment to Jira: ' + jiraKey);
    //             return true;
    //         } else {
    //             System.debug(LoggingLevel.ERROR, 'Failed to add comment. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody());
    //             return false;
    //         }
            
    //     } catch(Exception e) {
    //         System.debug(LoggingLevel.ERROR, 'Error adding comment to Jira: ' + e.getMessage());
    //         return false;
    //     }
    // }
    /**
     * Adds a comment to an existing Jira issue and RETURNS THE ID
     */
    public static String addCommentToJira(String jiraKey, String commentText, String authorName) {
        try {
            Map<String, Object> commentPayload = new Map<String, Object>{
                'body' => buildCommentADF(commentText, authorName)
            };
            
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:Jira_Cloud' + JIRA_API_VERSION + JIRA_ISSUE_ENDPOINT + '/' + jiraKey + '/comment');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(JSON.serialize(commentPayload));
            req.setTimeout(TIMEOUT_MS);
            
            Http http = new Http();
            HttpResponse res = http.send(req);
            
            if(res.getStatusCode() == 201) {
                // PARSE RESPONSE TO GET ID
                Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String commentId = (String) response.get('id');
                System.debug('Successfully added comment to Jira: ' + jiraKey + ' ID: ' + commentId);
                return commentId; // Return the actual ID
            } else {
                System.debug(LoggingLevel.ERROR, 'Failed to add comment. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody());
                return null;
            }
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error adding comment to Jira: ' + e.getMessage());
            return null;
        }
    }
    
    /**
     * Updates an existing comment in Jira
     * 
     * NEW METHOD: Handles comment updates/edits
     */
    public static Boolean updateCommentInJira(String jiraKey, String commentId, String commentText, String authorName) {
        try {
            Map<String, Object> commentPayload = new Map<String, Object>{
                'body' => buildCommentADF(commentText, authorName)
            };
            
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:Jira_Cloud' + JIRA_API_VERSION + JIRA_ISSUE_ENDPOINT + '/' + jiraKey + '/comment/' + commentId);
            req.setMethod('PUT');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(JSON.serialize(commentPayload));
            req.setTimeout(TIMEOUT_MS);
            
            Http http = new Http();
            HttpResponse res = http.send(req);
            
            if(res.getStatusCode() == 200) {
                System.debug('Successfully updated comment in Jira: ' + commentId);
                return true;
            } else {
                System.debug(LoggingLevel.ERROR, 'Failed to update comment. Status: ' + res.getStatusCode());
                return false;
            }
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error updating comment in Jira: ' + e.getMessage());
            return false;
        }
    }
    
    /**
     * Builds comment in Atlassian Document Format
     */
    private static Object buildCommentADF(String commentText, String authorName) {
        List<Object> content = new List<Object>();
        content.add(createParagraph('Comment from Salesforce by ' + authorName + ':'));
        content.add(new Map<String, Object>{'type' => 'rule'});
        
        List<String> lines = commentText.split('\n');
        for(String line : lines) {
            if(!String.isBlank(line)) {
                content.add(createParagraph(line));
            }
        }
        
        return new Map<String, Object>{
            'version' => 1,
            'type' => 'doc',
            'content' => content
        };
    }
    
    // All existing methods below (buildJiraPayload, callJiraAPI, etc.)
    
    private static Map<String, Object> buildJiraPayload(String projectKey, Case caseRecord, String aiSummary) {
        String jiraSummary = 'SF Case ' + caseRecord.CaseNumber;
        if(!String.isBlank(caseRecord.Subject)) {
            String subject = caseRecord.Subject.length() > 200 
                ? caseRecord.Subject.substring(0, 200) + '...' 
                : caseRecord.Subject;
            jiraSummary += ': ' + subject;
        }
        
        Object jiraDescription = buildJiraDescriptionADF(caseRecord, aiSummary);
        
        Map<String, Object> fields = new Map<String, Object>{
            'project' => new Map<String, String>{'key' => projectKey},
            'summary' => jiraSummary,
            'description' => jiraDescription,
            'issuetype' => new Map<String, String>{'name' => DEFAULT_ISSUE_TYPE}
        };
        
        if(!String.isBlank(caseRecord.Priority)) {
            fields.put('priority', new Map<String, String>{
                'name' => mapPriorityToJira(caseRecord.Priority)
            });
        }
        
        return new Map<String, Object>{'fields' => fields};
    }
    
    private static Object buildJiraDescriptionADF(Case caseRecord, String aiSummary) {
        List<Object> content = new List<Object>();
        
        if(!String.isBlank(aiSummary)) {
            List<String> lines = aiSummary.split('\n');
            for(String line : lines) {
                if(!String.isBlank(line)) {
                    content.add(createParagraph(line));
                }
            }
        }
        
        content.add(new Map<String, Object>{'type' => 'rule'});
        content.add(createParagraph('Source: Salesforce Case ' + caseRecord.CaseNumber));
        
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        String caseUrl = orgUrl + '/' + caseRecord.Id;
        content.add(createParagraphWithLink('View Case in Salesforce', caseUrl));
        
        if(!String.isBlank(caseRecord.ContactEmail)) {
            content.add(createParagraph('Contact: ' + caseRecord.ContactEmail));
        }
        
        return new Map<String, Object>{
            'version' => 1,
            'type' => 'doc',
            'content' => content
        };
    }
    
    private static Map<String, Object> createParagraph(String text) {
        return new Map<String, Object>{
            'type' => 'paragraph',
            'content' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'text',
                    'text' => text
                }
            }
        };
    }
    
    private static Map<String, Object> createParagraphWithLink(String linkText, String url) {
        return new Map<String, Object>{
            'type' => 'paragraph',
            'content' => new List<Object>{
                new Map<String, Object>{
                    'type' => 'text',
                    'text' => linkText,
                    'marks' => new List<Object>{
                        new Map<String, Object>{
                            'type' => 'link',
                            'attrs' => new Map<String, Object>{'href' => url}
                        }
                    }
                }
            }
        };
    }
    
    private static String mapPriorityToJira(String sfPriority) {
        Map<String, String> priorityMap = new Map<String, String>{
            'High' => 'High',
            'Medium' => 'Medium',
            'Low' => 'Low',
            'Critical' => 'Highest',
            'Urgent' => 'Highest'
        };
        return priorityMap.containsKey(sfPriority) ? priorityMap.get(sfPriority) : 'Medium';
    }
    
    private static String callJiraAPI(Map<String, Object> issueData) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Jira_Cloud' + JIRA_API_VERSION + JIRA_ISSUE_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(JSON.serialize(issueData));
        req.setTimeout(TIMEOUT_MS);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if(res.getStatusCode() == 201) {
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String jiraKey = (String) response.get('key');
            System.debug('Successfully created Jira issue: ' + jiraKey);
            return jiraKey;
        } else {
            String errorBody = res.getBody();
            System.debug(LoggingLevel.ERROR, 'Jira API Error: ' + errorBody);
            throw new CalloutException('Jira API Error (Status ' + res.getStatusCode() + '): ' + errorBody);
        }
    }
    
    private static void updateCaseWithJiraKey(Id caseId, String jiraKey) {
        Case updateCase = new Case(Id = caseId);
        updateCase.Jira_Issue_Key__c = jiraKey;
        updateCase.Escalation_Status__c = 'Completed';
        update updateCase;
        System.debug('Updated Case with Jira key: ' + jiraKey);
    }
    
    private static void handleJiraError(Id caseId, String errorMessage) {
        try {
            Case existingCase = [SELECT AI_Summary__c FROM Case WHERE Id = :caseId LIMIT 1];
            Case caseRecord = new Case(Id = caseId);
            caseRecord.Escalation_Status__c = 'Failed';
            String errorText = '\n\n--- Jira Integration Error ---\n' + errorMessage;
            String currentSummary = existingCase.AI_Summary__c != null ? existingCase.AI_Summary__c : '';
            caseRecord.AI_Summary__c = (currentSummary + errorText).length() > 32000
                ? (currentSummary + errorText).substring(0, 32000)
                : (currentSummary + errorText);
            update caseRecord;
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to update Case with error: ' + e.getMessage());
        }
    }
}