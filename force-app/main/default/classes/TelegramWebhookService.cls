// ========================================
// 1. TelegramWebhookService.cls
// ========================================
@RestResource(urlMapping='/telegram/webhook/*')
global with sharing class TelegramWebhookService {
    
    @HttpPost
    global static void handleWebhook() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        
        try {
            String requestBody = req.requestBody.toString();
            Map<String, Object> updateData = (Map<String, Object>) JSON.deserializeUntyped(requestBody);
            
            Map<String, Object> message = (Map<String, Object>) updateData.get('message');
            if (message == null) {
                res.statusCode = 200;
                return;
            }
            
            Map<String, Object> fromUser = (Map<String, Object>) message.get('from');
            String telegramUserId = String.valueOf(fromUser.get('id'));
            
            Map<String, Object> chat = (Map<String, Object>) message.get('chat');
            String chatId = String.valueOf(chat.get('id'));
            
            String messageText = (String) message.get('text');
            
            if (messageText != null && messageText.startsWith('/')) {
                handleCommand(chatId, telegramUserId, messageText);
                res.statusCode = 200;
                return;
            }
            
            if (messageText != null && messageText.trim().length() > 0) {
                processMessageAsync(chatId, telegramUserId, messageText);
            }
            
            res.statusCode = 200;
            
        } catch (Exception e) {
            System.debug('Error in webhook: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            res.statusCode = 200;
        }
    }
    
    @future(callout=true)
    private static void processMessageAsync(String chatId, String telegramUserId, String messageText) {
        try {
            TelegramService.sendChatAction(chatId, 'typing');
            
            AgentforceService.SessionInfo session = AgentforceService.getUserSession(telegramUserId);
            
            String agentResponse = AgentforceService.sendMessage(session, messageText);
            
            TelegramService.sendMessage(chatId, agentResponse);
            
        } catch (Exception e) {
            System.debug('Error processing message: ' + e.getMessage());
            System.debug('Stack trace: ' + e.getStackTraceString());
            TelegramService.sendMessage(chatId, 'Sorry, I encountered an error. Please try again.');
        }
    }
    
    private static void handleCommand(String chatId, String telegramUserId, String command) {
        if (command.equals('/start')) {
            TelegramService.sendMessage(chatId, 
                'Welcome to Salesforce Agentforce Bot! 🤖\n\n' +
                'Send me any message and I will help you.\n\n' +
                'Commands:\n' +
                '/start - Show this message\n' +
                '/reset - Reset your session');
        } else if (command.equals('/reset')) {
            AgentforceService.resetSession(telegramUserId);
            TelegramService.sendMessage(chatId, 
                'Your session has been reset. Your next message will start a fresh conversation.');
        }
    }
}