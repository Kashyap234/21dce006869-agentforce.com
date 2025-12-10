/**
 * AttachmentUploadQueueable - FIXED VERSION
 * 
 * Key Fix: Only uploads SPECIFIC files, not all files on the case
 * 
 * Changes:
 * 1. Added Set<Id> contentDocumentIds parameter
 * 2. Query filters to ONLY those specific ContentDocumentIds
 * 3. No longer queries all files on the case
 * 
 * @author Your Name
 * @date 2024
 */
public class AttachmentUploadQueueable implements Queueable, Database.AllowsCallouts {
    
    private Id caseId;
    private String jiraKey;
    private Set<Id> contentDocumentIds;  // NEW: Specific files to upload
    
    private static final Integer MAX_ATTACHMENTS = 5;
    private static final Integer MAX_FILE_SIZE = 10485760; // 10MB
    private static final Integer TIMEOUT_MS = 120000;
    
    // NEW CONSTRUCTOR: Accepts specific ContentDocumentIds
    public AttachmentUploadQueueable(Id caseId, String jiraKey, Set<Id> contentDocumentIds) {
        this.caseId = caseId;
        this.jiraKey = jiraKey;
        this.contentDocumentIds = contentDocumentIds;
    }
    
    // LEGACY CONSTRUCTOR: For backward compatibility (uploads all files)
    public AttachmentUploadQueueable(Id caseId, String jiraKey) {
        this.caseId = caseId;
        this.jiraKey = jiraKey;
        this.contentDocumentIds = null; // null means "all files"
    }
    
    public void execute(QueueableContext context) {
        try {
            System.debug('Starting attachment upload for Case: ' + this.caseId + ', Jira: ' + this.jiraKey);
            
            // FIXED: Query only specific ContentDocumentIds if provided
            List<ContentDocumentLink> docLinks;
            
            if(this.contentDocumentIds != null && !this.contentDocumentIds.isEmpty()) {
                // Upload ONLY the specified files
                System.debug('Uploading specific files: ' + this.contentDocumentIds);
                
                docLinks = [
                    SELECT ContentDocumentId, ContentDocument.Title, 
                           ContentDocument.FileExtension, ContentDocument.ContentSize
                    FROM ContentDocumentLink 
                    WHERE LinkedEntityId = :this.caseId 
                    AND ContentDocumentId IN :this.contentDocumentIds  // CRITICAL FIX
                    AND ContentDocument.ContentSize <= :MAX_FILE_SIZE
                    ORDER BY ContentDocument.CreatedDate DESC
                    LIMIT :MAX_ATTACHMENTS
                ];
            } else {
                // Fallback: Upload all files (legacy behavior)
                System.debug('Uploading all files on case');
                
                docLinks = [
                    SELECT ContentDocumentId, ContentDocument.Title, 
                           ContentDocument.FileExtension, ContentDocument.ContentSize
                    FROM ContentDocumentLink 
                    WHERE LinkedEntityId = :this.caseId 
                    AND ContentDocument.ContentSize <= :MAX_FILE_SIZE
                    ORDER BY ContentDocument.CreatedDate DESC
                    LIMIT :MAX_ATTACHMENTS
                ];
            }
            
            if(docLinks.isEmpty()) {
                System.debug('No attachments found for Case: ' + this.caseId);
                return;
            }
            
            // Get ContentVersions
            Set<Id> docIds = new Set<Id>();
            for(ContentDocumentLink link : docLinks) {
                docIds.add(link.ContentDocumentId);
            }
            
            List<ContentVersion> versions = [
                SELECT Id, Title, FileExtension, VersionData, ContentDocumentId
                FROM ContentVersion 
                WHERE ContentDocumentId IN :docIds 
                AND IsLatest = true
            ];
            
            // Upload each attachment
            Integer successCount = 0;
            for(ContentVersion cv : versions) {
                try {
                    Boolean success = uploadSingleAttachment(this.jiraKey, cv);
                    if(success) {
                        successCount++;
                    }
                } catch(Exception e) {
                    System.debug(LoggingLevel.ERROR, 'Failed to upload: ' + cv.Title + ' - ' + e.getMessage());
                    System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
                }
            }
            
            System.debug('Successfully uploaded ' + successCount + ' of ' + versions.size() + ' attachments');
            
        } catch(Exception e) {
            System.debug(LoggingLevel.ERROR, 'Attachment upload error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
        }
    }
    
    /**
     * Uploads a single file to Jira
     */
    private Boolean uploadSingleAttachment(String jiraKey, ContentVersion cv) {
        String boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW';
        String filename = cv.Title;
        if(!filename.contains('.') && !String.isBlank(cv.FileExtension)) {
            filename += '.' + cv.FileExtension;
        }
        
        // Get file data
        Blob fileBlob = cv.VersionData;
        
        // Build header
        String header = '--' + boundary + '\r\n';
        header += 'Content-Disposition: form-data; name="file"; filename="' + filename + '"\r\n';
        header += 'Content-Type: application/octet-stream\r\n\r\n';
        
        // Build footer
        String footer = '\r\n--' + boundary + '--';
        
        // Concatenate blobs properly
        Blob body = concatenateBlobs(
            Blob.valueOf(header),
            fileBlob,
            Blob.valueOf(footer)
        );
        
        // Create request
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:Jira_Cloud/rest/api/3/issue/' + jiraKey + '/attachments');
        req.setMethod('POST');
        req.setHeader('X-Atlassian-Token', 'no-check');
        req.setHeader('Content-Type', 'multipart/form-data; boundary=' + boundary);
        req.setBodyAsBlob(body);
        req.setTimeout(TIMEOUT_MS);
        
        Http http = new Http();
        HttpResponse res = http.send(req);
        
        if(res.getStatusCode() == 200) {
            System.debug('Successfully uploaded: ' + filename);
            return true;
        } else {
            System.debug(LoggingLevel.ERROR, 'Upload failed. Status: ' + res.getStatusCode() + ', Body: ' + res.getBody());
            return false;
        }
    }
    
    /**
     * Helper method to concatenate blobs without corrupting binary data
     */
    private Blob concatenateBlobs(Blob blob1, Blob blob2, Blob blob3) {
        String hex1 = EncodingUtil.convertToHex(blob1);
        String hex2 = EncodingUtil.convertToHex(blob2);
        String hex3 = EncodingUtil.convertToHex(blob3);
        
        String combinedHex = hex1 + hex2 + hex3;
        
        return EncodingUtil.convertFromHex(combinedHex);
    }
}