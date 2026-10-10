#import "NativeLanguageIdentifier.h"
#include "../ThirdParty/FastText/fasttext.h"
#include <algorithm>
#include <memory>
#include <mutex>
#include <sstream>
#include <unordered_map>

@implementation NativeLanguageIdentifier
+ (NSDictionary<NSString *, NSNumber *> *)hypothesesForText:(NSString *)text
                                                modelPath:(NSString *)modelPath
                                                    count:(NSInteger)count {
    static std::mutex mutex;
    static std::unordered_map<std::string, std::shared_ptr<fasttext::FastText>> models;
    std::lock_guard<std::mutex> lock(mutex);
    try {
        const std::string path(modelPath.fileSystemRepresentation);
        auto found = models.find(path);
        if (found == models.end()) {
            auto model = std::make_shared<fasttext::FastText>();
            model->loadModel(path);
            found = models.emplace(path, std::move(model)).first;
        }
        std::string input(text.UTF8String ?: "");
        std::replace(input.begin(), input.end(), '\n', ' ');
        std::replace(input.begin(), input.end(), '\r', ' ');
        // fastText's dictionary emits </s> only at a newline, not at EOF.
        // Match the reference CLI/training line boundary; omitting this changes
        // features and can turn clear Arabic/Han text into unrelated labels.
        input.push_back('\n');
        std::istringstream stream(input);
        std::vector<std::pair<fasttext::real, std::string>> predictions;
        found->second->predictLine(stream, predictions, int(std::max<NSInteger>(1, std::min<NSInteger>(count, 32))), 0);
        NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
        for (const auto &prediction : predictions) {
            NSString *label = [NSString stringWithUTF8String:prediction.second.c_str()];
            if (label != nil) result[label] = @(prediction.first);
        }
        return result;
    } catch (const std::exception &) {
        // A missing/corrupt model produces uncertainty, never an English guess.
        return @{};
    }
}
@end
