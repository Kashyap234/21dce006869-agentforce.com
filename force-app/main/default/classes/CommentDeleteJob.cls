/**
 * CommentDeleteJob - Wrapper class for comment deletion data
 * 
 * @author Your Name
 * @date 2024
 */
public class CommentDeleteJob {
    public String jiraKey;
    public String jiraCommentId;
    public Id salesforceCommentId;
    
    public CommentDeleteJob(String jiraKey, String jiraCommentId, Id salesforceCommentId) {
        this.jiraKey = jiraKey;
        this.jiraCommentId = jiraCommentId;
        this.salesforceCommentId = salesforceCommentId;
    }
}