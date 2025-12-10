/**
 * WebhookTestUtility - Manual testing utility for Jira webhooks
 * 
 * Use this class to test the webhook endpoint manually
 * Run in Anonymous Apex to verify webhook functionality
 */
public class WebhookTestUtility {
    
    /**
     * Simulates a Jira webhook call for testing
     * Run this in Anonymous Apex window:
     * WebhookTestUtility.testWebhookEndpoint();
     */
    public static void testWebhookEndpoint() {
        // Create test Case with Jira key
        Case testCase = new Case(
            Subject = 'Test Webhook Case',
            Description = 'Testing webhook integration',
            Status = 'Escalate to Engineering',
            Priority = 'Medium',
            Jira_Issue_Key__c = 'SFESC-13', // Use your actual Jira key
            Jira_Status__c = 'To Do'
        );
        insert testCase;
        
        System.debug('Created test Case: ' + testCase.Id);
        System.debug('Jira Key: ' + testCase.Jira_Issue_Key__c);
        
        // Now simulate webhook call
        String result = JiraWebhookService.updateCaseFromJira('SFESC-13', 'In Progress');
        System.debug('Webhook Result: ' + result);
        
        // Query updated case
        Case updatedCase = [SELECT Status, Jira_Status__c, Last_Jira_Sync__c 
                            FROM Case 
                            WHERE Id = :testCase.Id];
        
        System.debug('Updated Case Status: ' + updatedCase.Status);
        System.debug('Updated Jira Status: ' + updatedCase.Jira_Status__c);
        System.debug('Last Sync: ' + updatedCase.Last_Jira_Sync__c);
    }
    
    /**
     * Tests the complete webhook endpoint with authentication
     */
    public static void testFullWebhookFlow() {
        // Setup test data
        Case testCase = new Case(
            Subject = 'Test Full Webhook',
            Description = 'Testing complete webhook flow',
            Status = 'Escalate to Engineering',
            Priority = 'High',
            Jira_Issue_Key__c = 'SFESC-13',
            Jira_Status__c = 'To Do'
        );
        insert testCase;
        
        // Create webhook payload (simulating Jira)
        String payload = JSON.serialize(new Map<String, Object>{
            'webhookEvent' => 'jira:issue_updated',
            'issue' => new Map<String, Object>{
                'key' => 'SFESC-13',
                'fields' => new Map<String, Object>{
                    'status' => new Map<String, Object>{
                        'name' => 'In Progress'
                    }
                }
            },
            'changelog' => new Map<String, Object>{
                'items' => new List<Object>{
                    new Map<String, Object>{
                        'field' => 'status',
                        'fromString' => 'To Do',
                        'toString' => 'In Progress'
                    }
                }
            }
        });
        
        System.debug('Webhook Payload: ' + payload);
        
        // Create mock REST context
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        
        req.requestURI = '/services/apexrest/jira/webhook';
        req.httpMethod = 'POST';
        req.requestBody = Blob.valueOf(payload);
        
        // Add authentication header (get token from Custom Metadata)
        List<Integration_Config__mdt> configs = [
            SELECT API_Key__c 
            FROM Integration_Config__mdt 
            WHERE DeveloperName = 'Jira_Webhook_Token' 
            LIMIT 1
        ];
        
        if(!configs.isEmpty() && configs[0].API_Key__c != null) {
            req.headers.put('X-Jira-Webhook-Token', configs[0].API_Key__c);
            System.debug('Using webhook token from metadata');
        } else {
            System.debug('WARNING: No webhook token configured!');
        }
        
        RestContext.request = req;
        RestContext.response = res;
        
        // Call endpoint
        JiraWebhookEndpoint.WebhookResponse response = JiraWebhookEndpoint.handleWebhook();
        
        System.debug('Webhook Response: ' + JSON.serialize(response));
        System.debug('HTTP Status Code: ' + res.statusCode);
        
        // Verify results
        Case updatedCase = [SELECT Status, Jira_Status__c, Last_Jira_Sync__c 
                            FROM Case 
                            WHERE Id = :testCase.Id];
        
        System.debug('=== RESULTS ===');
        System.debug('Success: ' + response.success);
        System.debug('Message: ' + response.message);
        System.debug('Case Status: ' + updatedCase.Status);
        System.debug('Jira Status: ' + updatedCase.Jira_Status__c);
        System.debug('Last Sync: ' + updatedCase.Last_Jira_Sync__c);
    }
    
    /**
     * Displays your Salesforce webhook URL
     */
    public static void showWebhookURL() {
        String orgUrl = URL.getOrgDomainUrl().toExternalForm();
        String webhookUrl = orgUrl + '/services/apexrest/jira/webhook';
        
        System.debug('====================================');
        System.debug('YOUR JIRA WEBHOOK URL:');
        System.debug(webhookUrl);
        System.debug('====================================');
        System.debug('');
        System.debug('Configure this URL in Jira:');
        System.debug('1. Go to Jira Settings > System > Webhooks');
        System.debug('2. Create new webhook with this URL');
        System.debug('3. Select "Issue Updated" event');
        System.debug('4. Add header: X-Jira-Webhook-Token with your secret token');
    }
}