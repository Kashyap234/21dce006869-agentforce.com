/**
 * JiraAttachmentSyncService - Syncs attachments from Jira to Salesforce
 * 
 * Called by webhook when attachments are added to Jira issues
 * 
 * @author Your Name
 * @date 2024
 */
public class JiraAttachmentSyncService {
    
    private static final Integer MAX_FILE_SIZE = 10485760; // 10MB
    private static final Integer TIMEOUT_MS = 120000;
    
    /**
     * Downloads attachment from Jira and uploads to Salesforce Case
     * 
     * @param caseId Salesforce Case ID
     * @param attachmentId Jira attachment ID
     * @param attachmentUrl Jira attachment content URL
     * @param filename Original filename
     */
    public static void syncAttachmentFromJira(Id caseId, String attachmentId, String attachmentUrl, String filename) {
        try {
            System.debug('Syncing attachment from Jira: ' + filename);
            
            // Check if already synced (prevent duplicates)
            // List<ContentVersion> existing = [
            //     SELECT Id 
            //     FROM ContentVersion 
            //     WHERE Title = :filename
            //     AND ContentDocumentId IN (
            //         SELECT ContentDocumentId 
            //         FROM ContentDocumentLink 
            //         WHERE LinkedEntityId = :caseId
            //     )
            //     LIMIT 1
            // ];
            
            // if(!existing.isEmpty()) {
            //     System.debug('Attachment already exists, skipping: ' + filename);
            //     return;
            // }
            // Check if already synced (prevent duplicates)
// First get all ContentDocumentIds linked to this Case
            List<ContentDocumentLink> existingLinks = [
                SELECT ContentDocumentId 
                FROM ContentDocumentLink 
                WHERE LinkedEntityId = :caseId
            ];

            if(!existingLinks.isEmpty()) {
                Set<Id> contentDocIds = new Set<Id>();
                for(ContentDocumentLink link : existingLinks) {
                    contentDocIds.add(link.ContentDocumentId);
                }
                
                // Then check if our file already exists
                List<ContentVersion> existing = [
                    SELECT Id 
                    FROM ContentVersion 
                    WHERE Title = :filename
                    AND ContentDocumentId IN :contentDocIds
                    LIMIT 1
                ];
                
                if(!existing.isEmpty()) {
                    System.debug('Attachment already exists, skipping: ' + filename);
                    return;
                }
            }
            
            // Download from Jira
            Blob fileData = downloadFromJira(attachmentUrl);
            
            if(fileData == null || fileData.size() == 0) {
                System.debug(LoggingLevel.ERROR, 'Failed to download attachment: ' + filename);
                return;
            }
            
            if(fileData.size() > MAX_FILE_SIZE) {
                System.debug(LoggingLevel.WARN, 'File too large, skipping: ' + filename);
                return;
            }
            
            // Upload to Salesforce
            uploadToSalesforce(caseId, filename, fileData);
            
            System.debug('Successfully synced attachment: ' + filename);
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error syncing attachment: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
        }
    }
    
    // /**
    //  * Downloads file content from Jira
    //  */
    // private static Blob downloadFromJira(String attachmentUrl) {
    //     HttpRequest req = new HttpRequest();
        
    //     // Use the content URL directly (it already includes the full path)
    //     // Example: https://your-domain.atlassian.net/rest/api/2/attachment/content/10033
    //     req.setEndpoint('callout:Jira_Cloud' + attachmentUrl.substringAfter('atlassian.net'));
    //     req.setMethod('GET');
    //     req.setTimeout(TIMEOUT_MS);
        
    //     Http http = new Http();
    //     HttpResponse res = http.send(req);
        
    //     if(res.getStatusCode() == 200) {
    //         return res.getBodyAsBlob();
    //     } else {
    //         System.debug(LoggingLevel.ERROR, 'Jira download failed. Status: ' + res.getStatusCode());
    //         return null;
    //     }
    // }
    /**
     * Downloads file content from Jira (Updated to handle 303 Redirects)
     */
    private static Blob downloadFromJira(String attachmentUrl) {
        HttpRequest req = new HttpRequest();
        
        // 1. Initial Request to Jira via Named Credential
        // This request authenticates with Jira
        req.setEndpoint('callout:Jira_Cloud' + attachmentUrl.substringAfter('atlassian.net'));
        req.setMethod('GET');
        req.setTimeout(TIMEOUT_MS);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        // 2. Handle Redirects (302, 303, 307)
        // Jira returns 303 to redirect us to the actual file storage (e.g., AWS S3)
        if (res.getStatusCode() >= 300 && res.getStatusCode() <= 307) {
            String redirectUrl = res.getHeader('Location');
            
            if (String.isNotBlank(redirectUrl)) {
                System.debug('Jira redirected to: ' + redirectUrl);
                
                // Make a second request to the new URL
                // IMPORTANT: Do NOT use the Named Credential here. 
                // The redirect URL is pre-signed and works without extra auth.
                HttpRequest newReq = new HttpRequest();
                newReq.setEndpoint(redirectUrl);
                newReq.setMethod('GET');
                newReq.setTimeout(TIMEOUT_MS);
                
                res = http.send(newReq);
            }
        }
        
        // 3. Final Check
        if(res.getStatusCode() == 200) {
            return res.getBodyAsBlob();
        } else {
            System.debug(LoggingLevel.ERROR, 'Jira download failed. Final Status: ' + res.getStatusCode());
            System.debug(LoggingLevel.ERROR, 'Response Body: ' + res.getBody());
            return null;
        }
    }
    /**
     * Uploads file to Salesforce as ContentVersion
     */
    private static void uploadToSalesforce(Id caseId, String filename, Blob fileData) {
        // Create ContentVersion (this automatically creates ContentDocument)
        ContentVersion cv = new ContentVersion();
        cv.Title = filename;
        cv.PathOnClient = filename;
        cv.VersionData = fileData;
        cv.IsMajorVersion = true;
        cv.Origin = 'H'; // Uploaded by user (vs 'C' for Chatter)
        cv.FirstPublishLocationId = caseId;
        insert cv;
        
        // Query to get ContentDocumentId
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
        
        // Link to Case
        ContentDocumentLink cdl = new ContentDocumentLink();
        cdl.ContentDocumentId = cv.ContentDocumentId;
        cdl.LinkedEntityId = caseId;
        cdl.ShareType = 'V'; // Viewer permission
        cdl.Visibility = 'AllUsers';
        
        insert cdl;
    }
}