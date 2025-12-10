public without sharing class AgentforceService {
    
    private static final String AGENT_ID = '0XxgL000000nbHmSAI';
    private static final String INSTANCE_URL = 'https://orgfarm-c1f6728853-dev-ed.develop.my.salesforce.com';
    private static final String TOKEN_ENDPOINT = '/services/oauth2/token';
    
    // Your Connected App credentials
    private static final String CLIENT_ID = '3MVG9dAEux2v1sLsZdgUt_m24mCFww.XjrAWpzIhuUz8N9i5XCL_oyiOXlVAyhHmPha_ENyUwYH46ylJ1VZ9Q';
    private static final String CLIENT_SECRET = '2182C98F72F1E7F645AF8EAEFA7BA24CAE05359C1C3AD5332BD9C23B991AE6B1';
    
    // Your integration user credentials (with Einstein Agent User license)
    private static final String USERNAME = 'telegram_integration@00dgl00000dk5ppual.org.force.com';
    private static final String PASSWORD = 'YOUR_PASSWORD'; // Add your password
    private static final String SECURITY_TOKEN = 'YOUR_SECURITY_TOKEN'; // Add your security token
    
    public class SessionInfo {
        public String accessToken;
        public String apiURL;
        public String sessionId;
    }
    
    public class AgentforceException extends Exception {}
    
    public static SessionInfo getUserSession(String telegramUserId) {
        List<Telegram_Session__c> sessionList = [
            SELECT Agent_Session_ID__c, Access_Token__c, Last_Activity__c
            FROM Telegram_Session__c
            WHERE Telegram_User_ID__c = :telegramUserId
            LIMIT 1
        ];
        
        SessionInfo sessionInfo;
        
        if (!sessionList.isEmpty() && 
            sessionList[0].Last_Activity__c != null && 
            sessionList[0].Last_Activity__c > DateTime.now().addHours(-1) &&
            sessionList[0].Access_Token__c != null) {
            
            Telegram_Session__c existingSession = sessionList[0];
            sessionInfo = new SessionInfo();
            sessionInfo.accessToken = existingSession.Access_Token__c;
            sessionInfo.apiURL = INSTANCE_URL;
            sessionInfo.sessionId = existingSession.Agent_Session_ID__c;
            
            existingSession.Last_Activity__c = DateTime.now();
            update existingSession;
            
        } else {
            sessionInfo = createNewSession(telegramUserId);
        }
        
        return sessionInfo;
    }
    
    private static SessionInfo createNewSession(String telegramUserId) {
        String accessToken = getAccessToken();
        String sessionId = createAgentSession(accessToken);
        
        Telegram_Session__c newSession = new Telegram_Session__c(
            Telegram_User_ID__c = telegramUserId,
            Agent_Session_ID__c = sessionId,
            Access_Token__c = accessToken,
            Last_Activity__c = DateTime.now()
        );
        
        upsert newSession Telegram_User_ID__c;
        
        SessionInfo sessionInfo = new SessionInfo();
        sessionInfo.accessToken = accessToken;
        sessionInfo.apiURL = INSTANCE_URL;
        sessionInfo.sessionId = sessionId;
        
        return sessionInfo;
    }
    
    // Use Username-Password OAuth Flow (no rate limits!)
    private static String getAccessToken() {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(INSTANCE_URL + TOKEN_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        
        String body = 'grant_type=password' +
                     '&client_id=' + EncodingUtil.urlEncode(CLIENT_ID, 'UTF-8') +
                     '&client_secret=' + EncodingUtil.urlEncode(CLIENT_SECRET, 'UTF-8') +
                     '&username=' + EncodingUtil.urlEncode(USERNAME, 'UTF-8') +
                     '&password=' + EncodingUtil.urlEncode(PASSWORD + SECURITY_TOKEN, 'UTF-8');
        
        req.setBody(body);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        System.debug('Auth Response: ' + res.getStatusCode() + ' - ' + res.getBody());
        
        if (res.getStatusCode() != 200) {
            throw new AgentforceException('Failed to get access token: ' + res.getBody());
        }
        
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) result.get('access_token');
    }
    
    private static String createAgentSession(String accessToken) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(INSTANCE_URL + '/services/data/v64.0/connect/einstein/ai-agent/v1/agents/' + AGENT_ID + '/sessions');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        
        Map<String, Object> requestBody = new Map<String, Object>{
            'externalSessionKey' => 'sf_' + String.valueOf(DateTime.now().getTime()) + '_' + 
                                    String.valueOf(Math.random()).substring(2, 11),
            'instanceConfig' => new Map<String, Object>{
                'endpoint' => INSTANCE_URL
            },
            'streamingCapabilities' => new Map<String, Object>{
                'chunkTypes' => new List<String>{ 'Text' }
            }
        };
        
        req.setBody(JSON.serialize(requestBody));
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        System.debug('Create Session Response: ' + res.getStatusCode() + ' - ' + res.getBody());
        
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new AgentforceException('Failed to create session: ' + res.getBody());
        }
        
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String sessionId = (String) result.get('sessionId');
        
        if (sessionId == null && result.containsKey('data')) {
            Map<String, Object> data = (Map<String, Object>) result.get('data');
            sessionId = (String) data.get('sessionId');
        }
        
        if (sessionId == null) {
            sessionId = (String) result.get('id');
        }
        
        if (sessionId == null) {
            throw new AgentforceException('Could not extract sessionId from response');
        }
        
        return sessionId;
    }
    
    public static String sendMessage(SessionInfo session, String messageText) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(INSTANCE_URL + '/services/data/v62.0/connect/einstein/ai-agent/v1/sessions/' + session.sessionId + '/messages');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Authorization', 'Bearer ' + session.accessToken);
        
        Map<String, Object> requestBody = new Map<String, Object>{
            'message' => new Map<String, Object>{
                'sequenceId' => DateTime.now().getTime(),
                'type' => 'Text',
                'text' => messageText
            },
            'variables' => new List<Object>()
        };
        
        req.setBody(JSON.serialize(requestBody));
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        System.debug('Send Message Response: ' + res.getStatusCode() + ' - ' + res.getBody());
        
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new AgentforceException('Failed to send message: ' + res.getBody());
        }
        
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> messages = (List<Object>) result.get('messages');
        
        if (messages != null && !messages.isEmpty()) {
            Map<String, Object> firstMessage = (Map<String, Object>) messages[0];
            return (String) firstMessage.get('message');
        }
        
        return 'No response from agent';
    }
    
    public static void resetSession(String telegramUserId) {
        List<Telegram_Session__c> sessionList = [
            SELECT Id FROM Telegram_Session__c
            WHERE Telegram_User_ID__c = :telegramUserId
        ];
        
        if (!sessionList.isEmpty()) {
            delete sessionList;
        }
    }
}