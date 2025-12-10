/**
 * CommentSyncJob - Wrapper class for comment sync data
 * 
 * @author Your Name
 * @date 2024
 */
public class CommentSyncJob {
    public Id commentId;
    public String jiraKey;
    public String commentText;
    public Id authorId;
    public String caseNumber;
    public Boolean isUpdate;
    
    public CommentSyncJob(Id commentId, String jiraKey, String commentText, Id authorId, String caseNumber, Boolean isUpdate) {
        this.commentId = commentId;
        this.jiraKey = jiraKey;
        this.commentText = commentText;
        this.authorId = authorId;
        this.caseNumber = caseNumber;
        this.isUpdate = isUpdate;
    }
}