/**
 * GeminiAIService - Handles AI-powered bug report generation
 * 
 * Purpose: This class interacts with Google Gemini AI API to automatically
 * generate technical bug reports from customer support conversations.
 * 
 * Key Features:
 * - Asynchronous processing using @future
 * - Error handling and logging
 * - Integration with JiraService
 * 
 * Dependencies:
 * - Custom Metadata Type: Integration_Config__mdt
 * - Named Credential: Gemini_AI
 * - Custom Fields on Case: AI_Summary__c, Escalation_Status__c
 * 
 * @author Your Name
 * @date 2024
 */
public class GeminiAIService {
    
    // Constants for better maintainability
    private static final String GEMINI_MODEL = 'gemini-2.5-flash';
    private static final Integer TIMEOUT_MS = 120000; // 2 minutes
    private static final Integer MAX_EMAILS = 10;
    
    /**
     * Main entry point - Processes case escalation asynchronously
     * 
     * This method runs in a separate thread and can make HTTP callouts.
     * It orchestrates the entire flow: query data → call AI → update case → create Jira
     * 
     * @param caseId The Salesforce Case Id to process
     * 
     * @example
     * GeminiAIService.getSummaryAndCreateJira('5001234567890ABC');
     * 
     * Governor Limits Impact:
     * - 1 SOQL query for Case
     * - 1 SOQL query for EmailMessages
     * - 1 SOQL query for Custom Metadata (inside callGeminiAPI)
     * - 2 HTTP callouts (Gemini + Jira)
     * - 2 DML operations (update Case twice)
     */
    @future(callout=true)
    public static void getSummaryAndCreateJira(Id caseId) {
        try {
            // STEP 1: Query the Case record
            // We need all fields that will be sent to AI and displayed in Jira
            Case caseRecord = [
                SELECT Id, Subject, Description, 
                       SuppliedEmail, Status, CaseNumber
                FROM Case 
                WHERE Id = :caseId 
                LIMIT 1
            ];
            
            // STEP 2: Query related Email Messages
            // Get up to 10 most recent emails for context
            // Ordered chronologically to show conversation flow
            List<EmailMessage> emails = [
                SELECT TextBody, Subject, CreatedDate 
                FROM EmailMessage 
                WHERE ParentId = :caseId 
                ORDER BY CreatedDate ASC 
                LIMIT :MAX_EMAILS
            ];
            
            // STEP 3: Build context string for AI
            // This creates a formatted conversation that AI can understand
            String conversationContext = buildContext(caseRecord, emails);
            
            // STEP 4: Call Gemini AI API
            // This is where the magic happens - AI analyzes and structures the data
            String aiSummary = callGeminiAPI(conversationContext);
            
            // STEP 5: Update Case with AI-generated summary
            // Set status to 'Processing' to indicate Jira creation is next
            caseRecord.AI_Summary__c = aiSummary;
            caseRecord.Escalation_Status__c = 'Processing';
            update caseRecord;
            
            // STEP 6: Queue Jira ticket creation
            // IMPORTANT: We use Queueable instead of direct call because:
            // - Salesforce doesn't allow HTTP callouts after DML in same transaction
            // - Queueable runs in a separate transaction, allowing the callout
            System.enqueueJob(new JiraQueueable(caseId, aiSummary));
            
        } catch(Exception e) {
            // Catch any errors and update the Case record
            // This ensures users know something went wrong
            handleError(caseId, e.getMessage());
            
            // Log to debug logs for admin troubleshooting
            System.debug(LoggingLevel.ERROR, 'Error in getSummaryAndCreateJira: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
        }
    }
    
    /**
     * Builds formatted context string from Case and Emails
     * 
     * This method takes raw Salesforce data and formats it into a structure
     * that's optimized for AI comprehension. The format includes:
     * - Case metadata (number, subject, description)
     * - Email conversation history in chronological order
     * 
     * @param caseRecord The Case being escalated
     * @param emails List of related EmailMessages
     * @return Formatted string ready for AI processing
     * 
     * Example Output:
     * ---
     * Case Number: 00001234
     * Subject: Login button not working
     * Description: Customer reports issue with login
     * 
     * Email History:
     * ---
     * Subject: Login Issue
     * Customer says: I can't click the login button...
     * ---
     */
    private static String buildContext(Case caseRecord, List<EmailMessage> emails) {
        // Initialize with case details
        String context = 'Case Number: ' + caseRecord.CaseNumber + '\n';
        context += 'Subject: ' + caseRecord.Subject + '\n';
        
        // Handle null description gracefully
        context += 'Description: ' + (caseRecord.Description != null ? caseRecord.Description : 'No description provided') + '\n\n';
        
        // Add email conversation if exists
        if(!emails.isEmpty()) {
            context += 'Email History:\n';
            
            for(EmailMessage email : emails) {
                context += '---\n';
                context += 'Subject: ' + (email.Subject != null ? email.Subject : 'No Subject') + '\n';
                
                // Handle null email body
                if(email.TextBody != null) {
                    // Limit email body length to prevent token overflow
                    // Gemini has input limits, so we truncate very long emails
                    String emailBody = email.TextBody.length() > 2000 
                        ? email.TextBody.substring(0, 2000) + '...[truncated]' 
                        : email.TextBody;
                    context += emailBody + '\n';
                } else {
                    context += '[No email body]\n';
                }
            }
        } else {
            context += '\nEmail History: No emails found\n';
        }
        
        return context;
    }
    
    /**
     * Makes HTTP callout to Gemini AI API
     * 
     * This method handles the entire API interaction:
     * 1. Retrieves API key from Custom Metadata
     * 2. Constructs the prompt with specific instructions
     * 3. Builds JSON request body
     * 4. Makes HTTP POST request
     * 5. Parses response and extracts generated text
     * 
     * @param context The formatted conversation context
     * @return AI-generated bug report as formatted text
     * @throws CalloutException if API returns error
     * 
     * API Response Structure:
     * {
     *   "candidates": [{
     *     "content": {
     *       "parts": [{
     *         "text": "**Summary**: Bug description..."
     *       }]
     *     }
     *   }]
     * }
     */
    private static String callGeminiAPI(String context) {
        // STEP 1: Get API key from Custom Metadata
        // This keeps sensitive data secure and easy to update
        Integration_Config__mdt config = [
            SELECT API_Key__c 
            FROM Integration_Config__mdt 
            WHERE DeveloperName = 'Gemini_API' 
            LIMIT 1
        ];
        
        // Validate API key exists
        if(config == null || String.isBlank(config.API_Key__c)) {
            throw new CalloutException('Gemini API key not found in Custom Metadata');
        }
        
        // STEP 2: Build the AI prompt
        // This is crucial - a well-structured prompt gets better results
        String prompt = 
            'Analyze this customer support conversation and create a technical bug report with these sections:\n\n' +
            '1. **Summary**: One-line description of the issue\n' +
            '2. **Steps to Reproduce**: Numbered list of exact steps\n' +
            '3. **Expected Behavior**: What should happen normally\n' +
            '4. **Actual Behavior**: What is actually happening (the bug)\n' +
            '5. **Priority**: Rate as Critical/High/Medium/Low based on impact\n\n' +
            'Be concise but technical. Use developer-friendly language.\n\n' +
            'Conversation:\n' + context;
        
        // STEP 3: Build JSON request body matching Gemini API format
        // Structure follows Google's Generative AI API specification
        Map<String, Object> requestBody = new Map<String, Object>{
            'contents' => new List<Object>{
                new Map<String, Object>{
                    'parts' => new List<Object>{
                        new Map<String, String>{'text' => prompt}
                    }
                }
            },
            // Optional: Add generation config for better control
            'generationConfig' => new Map<String, Object>{
                'temperature' => 0.4, // Lower = more focused/deterministic
                'maxOutputTokens' => 2048
            }
        };
        
        // STEP 4: Configure HTTP request
        HttpRequest req = new HttpRequest();
        
        // Use Named Credential for the base URL (handles authentication)
        // Append API key as query parameter (Gemini's auth method)
        req.setEndpoint(
            'callout:Gemini_AI/v1beta/models/' + GEMINI_MODEL + ':generateContent?key=' + config.API_Key__c
        );
        
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(requestBody));
        req.setTimeout(TIMEOUT_MS); // 2 minutes for AI processing
        
        // STEP 5: Send request
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        // STEP 6: Handle response
        if(res.getStatusCode() == 200) {
            // Parse JSON response
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            
            // Navigate through nested structure to get the text
            List<Object> candidates = (List<Object>) response.get('candidates');
            
            if(candidates == null || candidates.isEmpty()) {
                throw new CalloutException('No candidates in Gemini response');
            }
            
            Map<String, Object> candidate = (Map<String, Object>) candidates[0];
            Map<String, Object> content = (Map<String, Object>) candidate.get('content');
            List<Object> parts = (List<Object>) content.get('parts');
            Map<String, Object> part = (Map<String, Object>) parts[0];
            
            String generatedText = (String) part.get('text');
            
            // Validate we got actual content
            if(String.isBlank(generatedText)) {
                throw new CalloutException('Gemini returned empty response');
            }
            
            return generatedText;
            
        } else {
            // API returned an error - throw exception with details
            String errorBody = res.getBody();
            System.debug(LoggingLevel.ERROR, 'Gemini API Error Response: ' + errorBody);
            throw new CalloutException('Gemini API Error (Status ' + res.getStatusCode() + '): ' + errorBody);
        }
    }
    
    /**
     * Handles errors by updating Case record with failure status
     * 
     * This ensures the Case doesn't get "stuck" in a processing state.
     * Users will see the error message and can take action (retry, manual escalation).
     * 
     * @param caseId The Case Id that encountered an error
     * @param errorMessage The error message to display
     */
    private static void handleError(Id caseId, String errorMessage) {
        try {
            Case caseRecord = new Case(Id = caseId);
            caseRecord.Escalation_Status__c = 'Failed';
            
            // Store error in AI_Summary field so users can see what went wrong
            // Truncate if necessary to fit field limits
            String errorText = 'Error during AI processing: ' + errorMessage;
            caseRecord.AI_Summary__c = errorText.length() > 32000 
                ? errorText.substring(0, 32000) 
                : errorText;
            
            update caseRecord;
        } catch(Exception e) {
            // If even the error handling fails, log it
            // Don't throw - we're already in error state
            System.debug(LoggingLevel.ERROR, 'Failed to update Case with error: ' + e.getMessage());
        }
    }
}