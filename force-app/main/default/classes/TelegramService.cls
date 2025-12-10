// ========================================
// 3. TelegramService.cls
// ========================================
public class TelegramService {
    
    // TODO: Move to Custom Metadata Type
    private static final String TELEGRAM_BOT_TOKEN = '8224121064:AAELPLu61zbSN52hhvhiBvPbZs27o1U4iZQ';
    private static final String TELEGRAM_API_URL = 'https://api.telegram.org/bot' + TELEGRAM_BOT_TOKEN;
    
    public static void sendMessage(String chatId, String text) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(TELEGRAM_API_URL + '/sendMessage');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        
        Map<String, Object> requestBody = new Map<String, Object>{
            'chat_id' => chatId,
            'text' => text,
            'parse_mode' => 'HTML'
        };
        
        req.setBody(JSON.serialize(requestBody));
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if (res.getStatusCode() != 200) {
            System.debug('Failed to send Telegram message: ' + res.getBody());
        }
    }
    
    public static void sendChatAction(String chatId, String action) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(TELEGRAM_API_URL + '/sendChatAction');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        
        Map<String, Object> requestBody = new Map<String, Object>{
            'chat_id' => chatId,
            'action' => action
        };
        
        req.setBody(JSON.serialize(requestBody));
        
        Http http = new Http();
        http.send(req);
    }
}