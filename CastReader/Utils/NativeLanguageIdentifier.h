#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read-only local inference. Model labels are returned unchanged; product
/// capability and uncertainty policy remain in Swift.
@interface NativeLanguageIdentifier : NSObject
+ (NSDictionary<NSString *, NSNumber *> *)hypothesesForText:(NSString *)text
                                                modelPath:(NSString *)modelPath
                                                    count:(NSInteger)count
    NS_SWIFT_NAME(hypotheses(for:modelPath:count:));
@end
NS_ASSUME_NONNULL_END
