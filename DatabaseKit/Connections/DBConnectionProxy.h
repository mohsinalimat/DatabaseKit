#import <Foundation/Foundation.h>
@class DBConnection;

@interface DBConnectionProxy : NSProxy
@property(nonatomic, readonly) NSURL *connectionURL;
@property(nonatomic, readonly, copy) DBConnection *connection;

+ (instancetype)connectionProxyWithURL:(NSURL *)URL error:(NSError **)err;
- (DBConnection *)connection:(NSError **)outErr;
@end
