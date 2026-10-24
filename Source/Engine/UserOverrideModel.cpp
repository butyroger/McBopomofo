// Copyright (c) 2017 ond onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//

#include "UserOverrideModel.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <list>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#include "gramambular2/reading_grid.h"

namespace McBopomofo {

// Fully decay after about 20 generations.
static constexpr double kDecayThreshold = 1.0 / 1048576.0;

static constexpr char kEmptyNodeString[] = "()";

// A scoring function that balances between "recent but infrequently observed"
// and "old but frequently observed".
static double Score(size_t eventCount, size_t totalCount, double eventTimestamp,
                    double timestamp, double lambda);

// Form the observation key from the nodes of a walk. This goes backward, but
// we are using a const_iterator, the "end" here should be a .cbegin() of a
// vector.
static std::string FormObservationKey(
    std::vector<Formosa::Gramambular2::ReadingGrid::NodePtr>::const_iterator
        head,
    std::vector<Formosa::Gramambular2::ReadingGrid::NodePtr>::const_iterator
        end);

UserOverrideModel::UserOverrideModel(size_t capacity, double decayConstant)
    : capacity_(capacity) {
  assert(capacity_ > 0);
  // NOLINTNEXTLINE(readability-magic-numbers)
  decayExponent_ = log(0.5) / decayConstant;
}

void UserOverrideModel::observe(
    const Formosa::Gramambular2::ReadingGrid::WalkResult&
        walkBeforeUserOverride,
    const Formosa::Gramambular2::ReadingGrid::WalkResult& walkAfterUserOverride,
    size_t cursor, double timestamp) {
  // Sanity check.
  if (walkBeforeUserOverride.nodes.empty() ||
      walkAfterUserOverride.nodes.empty()) {
    return;
  }

  if (walkBeforeUserOverride.totalReadings !=
      walkAfterUserOverride.totalReadings) {
    return;
  }

  // We first infer what the user override is.
  size_t actualCursor = 0;
  auto currentNodeIt = walkAfterUserOverride.findNodeAt(cursor, &actualCursor);
  if (currentNodeIt == walkAfterUserOverride.nodes.cend()) {
    return;
  }

  // Based on previous analysis, we found it meaningless to handle phrases
  // over 3 characters.
  if ((*currentNodeIt)->spanningLength() > 3) {
    return;
  }

  // Now we need to find the head node in the previous walk (that is, before
  // the user override). Remember that actualCursor now is actually *past*
  // the current node, so we need to decrement by 1.
  if (actualCursor == 0) {
    // Shouldn't happen.
    return;
  }
  --actualCursor;
  auto prevHeadNodeIt = walkBeforeUserOverride.findNodeAt(actualCursor);
  if (prevHeadNodeIt == walkBeforeUserOverride.nodes.cend()) {
    return;
  }

  // Now we have everything. We want to handle the following cases:
  // (1) both prev and current head nodes represent an n-char phrase.
  // (2) current head node is a 2-/3-char phrase but prev head node and
  //     the nodes that lead to the prev head node are 1-char phrases.
  // (3) current head node is a 1-char phrase but the prev head node is
  //     a phrase of multi-char phrases.
  //
  // (1) is the simplest case. Our observation is based on the "walk before
  // user override", and we don't need to recommend force-high-score
  // overrides when we return such a suggestion. Example: overriding
  // "他姓[中]" with "他姓[鍾]".
  //
  // (2) is a case that UOM historically didn't handle properly. The
  // observation needs to be based on the walk before user override, but
  // we also need to recommend force-high-score override when we make the
  // suggestion, due to the fact (based on our data analysis) that many
  // n-char (esp. 2-char) phrases need to compete with individual chars
  // that together have higher score than the phrases themselves. Example:
  // overriding "增加[自][會]" with "增加[字彙]". Here [自][會] together have
  // higher score than the single unigram [字彙], and hence the boosting
  // here.
  //
  // (3) is a very special case where we need to base our observation on
  // the walk *after* user override. This is because when (3) happens, the
  // user intent is to break up a long phrase. We don't want to recommend
  // force-high-score overrides, which would cause the multi-char phrase
  // to lose over the user override all the time. For example (a somewhat
  // forced one): overriding "[三百元]" with "[參]百元".
  const auto& currentNode = *currentNodeIt;
  const auto& prevHeadNode = *prevHeadNodeIt;
  bool forceHighScoreOverride =
      currentNode->spanningLength() > prevHeadNode->spanningLength();
  bool breakingUp =
      currentNode->spanningLength() == 1 && prevHeadNode->spanningLength() > 1;

  auto nodeIter = breakingUp ? currentNodeIt : prevHeadNodeIt;
  auto endPoint = breakingUp ? walkAfterUserOverride.nodes.begin()
                             : walkBeforeUserOverride.nodes.begin();

  std::string key = FormObservationKey(nodeIter, endPoint);
  observe(key, currentNode->currentUnigram().value(), timestamp,
          forceHighScoreOverride);
}

UserOverrideModel::Suggestion UserOverrideModel::suggest(
    const Formosa::Gramambular2::ReadingGrid::WalkResult& currentWalk,
    size_t cursor, double timestamp) {
  auto nodeIter = currentWalk.findNodeAt(cursor);
  std::string key = FormObservationKey(nodeIter, currentWalk.nodes.begin());
  return suggest(key, timestamp);
}

void UserOverrideModel::observe(const std::string& key,
                                const std::string& candidate, double timestamp,
                                bool forceHighScoreOverride) {
  auto mapIter = lruMap_.find(key);
  if (mapIter == lruMap_.end()) {
    auto keyValuePair = KeyObservationPair(key, Observation());
    Observation& observation = keyValuePair.second;
    observation.update(candidate, timestamp, forceHighScoreOverride);

    lruList_.push_front(keyValuePair);
    auto listIter = lruList_.begin();
    auto lruKeyValue =
        std::pair<std::string, std::list<KeyObservationPair>::iterator>(
            key, listIter);
    lruMap_.insert(lruKeyValue);

    if (lruList_.size() > capacity_) {
      auto lastKeyValuePair = lruList_.end();
      --lastKeyValuePair;
      lruMap_.erase(lastKeyValuePair->first);
      lruList_.pop_back();
    }
  } else {
    auto listIter = mapIter->second;
    lruList_.splice(lruList_.begin(), lruList_, listIter);

    auto& keyValuePair = *listIter;
    Observation& observation = keyValuePair.second;
    observation.update(candidate, timestamp, forceHighScoreOverride);
  }
}

UserOverrideModel::Suggestion UserOverrideModel::suggest(const std::string& key,
                                                         double timestamp) {
  auto mapIter = lruMap_.find(key);
  if (mapIter == lruMap_.end()) {
    return UserOverrideModel::Suggestion{};
  }

  auto listIter = mapIter->second;
  auto& keyValuePair = *listIter;
  const Observation& observation = keyValuePair.second;

  // The most recent choice wins, so that the user can always correct a
  // wrong choice by simply choosing again. The score is only used to tell if
  // a choice has decayed.
  std::string candidate;
  bool forceHighScoreOverride = false;
  double latestTimestamp = 0;
  for (auto i = observation.overrides.begin(); i != observation.overrides.end();
       ++i) {
    const Override& o = i->second;
    double overrideScore = Score(o.count, observation.count, o.timestamp,
                                 timestamp, decayExponent_);
    if (overrideScore == 0.0) {
      continue;
    }

    if (candidate.empty() || o.timestamp > latestTimestamp) {
      candidate = i->first;
      forceHighScoreOverride = o.forceHighScoreOverride;
      latestTimestamp = o.timestamp;
    }
  }
  return UserOverrideModel::Suggestion{candidate, forceHighScoreOverride};
}

size_t UserOverrideModel::candidateObservationCount(
    const std::string& candidate) const {
  size_t count = 0;
  for (const auto& keyValuePair : lruList_) {
    const auto& overrides = keyValuePair.second.overrides;
    auto it = overrides.find(candidate);
    if (it != overrides.end()) {
      count += it->second.count;
    }
  }
  return count;
}

size_t UserOverrideModel::observationCount(
    const Formosa::Gramambular2::ReadingGrid::WalkResult& walk, size_t cursor,
    const std::string& candidate) const {
  auto nodeIter = walk.findNodeAt(cursor);
  if (nodeIter == walk.nodes.cend()) {
    return 0;
  }
  auto mapIter = lruMap_.find(FormObservationKey(nodeIter, walk.nodes.begin()));
  if (mapIter == lruMap_.end()) {
    return 0;
  }
  const auto& overrides = mapIter->second->second.overrides;
  auto it = overrides.find(candidate);
  return it == overrides.end() ? 0 : it->second.count;
}

std::string UserOverrideModel::serialize() const {
  std::ostringstream out;
  out.precision(17);
  for (auto it = lruList_.rbegin(); it != lruList_.rend(); ++it) {
    for (const auto& [candidate, o] : it->second.overrides) {
      out << it->first << '\t' << candidate << '\t' << o.count << '\t'
          << o.timestamp << '\t' << (o.forceHighScoreOverride ? 1 : 0)
          << '\n';
    }
  }
  return out.str();
}

size_t UserOverrideModel::deserialize(const std::string& text, bool append) {
  if (!append) {
    lruList_.clear();
    lruMap_.clear();
  }

  size_t loaded = 0;
  std::istringstream in(text);
  std::string line;
  while (std::getline(in, line)) {
    std::vector<std::string> fields;
    size_t start = 0;
    while (true) {
      size_t tab = line.find('\t', start);
      fields.push_back(line.substr(start, tab - start));
      if (tab == std::string::npos) {
        break;
      }
      start = tab + 1;
    }
    // NOLINTNEXTLINE(readability-magic-numbers)
    if (fields.size() != 5 || fields[0].empty() || fields[1].empty()) {
      continue;
    }

    size_t count = 0;
    double timestamp = 0;
    try {
      count = std::stoul(fields[2]);
      timestamp = std::stod(fields[3]);
    } catch (...) {
      continue;
    }
    if (count == 0) {
      continue;
    }

    const std::string& key = fields[0];
    auto mapIter = lruMap_.find(key);
    if (mapIter == lruMap_.end()) {
      lruList_.emplace_front(key, Observation());
      mapIter = lruMap_.emplace(key, lruList_.begin()).first;
    } else {
      lruList_.splice(lruList_.begin(), lruList_, mapIter->second);
    }

    Observation& observation = mapIter->second->second;
    Override& o = observation.overrides[fields[1]];
    observation.count += count;
    o.count += count;
    o.timestamp = std::max(o.timestamp, timestamp);
    o.forceHighScoreOverride = fields[4] == "1";
    ++loaded;
  }

  while (lruList_.size() > capacity_) {
    lruMap_.erase(lruList_.back().first);
    lruList_.pop_back();
  }
  return loaded;
}

void UserOverrideModel::Observation::update(const std::string& candidate,
                                            double timestamp,
                                            bool forceHighScoreOverride) {
  count++;
  auto& o = overrides[candidate];
  o.timestamp = timestamp;
  o.count++;
  o.forceHighScoreOverride = forceHighScoreOverride;
}

static double Score(size_t eventCount, size_t totalCount, double eventTimestamp,
                    double timestamp, double lambda) {
  double decay = exp((timestamp - eventTimestamp) * lambda);
  if (decay < kDecayThreshold) {
    return 0.0;
  }

  double prob =
      static_cast<double>(eventCount) / static_cast<double>(totalCount);
  return prob * decay;
}

static std::string CombineReadingValue(const std::string& reading,
                                       const std::string& value) {
  return std::string("(") + reading + "," + value + ")";
}

static bool IsPunctuation(
    const Formosa::Gramambular2::ReadingGrid::NodePtr& node) {
  const std::string& reading = node->reading();
  return !reading.empty() && reading[0] == '_';
}

static std::string FormObservationKey(
    std::vector<Formosa::Gramambular2::ReadingGrid::NodePtr>::const_iterator
        head,
    std::vector<Formosa::Gramambular2::ReadingGrid::NodePtr>::const_iterator
        end) {
  // Using the top unigram from the head node. Recall that this is an
  // observation for *before* the user override, and when we provide
  // a suggestion, this head node is never overridden yet.
  std::string headStr =
      CombineReadingValue((*head)->reading(), (*head)->unigrams()[0].value());

  // For the next two nodes, use their current unigram values. If it's a
  // punctuation, we ignore the reading and the value altogether and treat
  // it as if it's like the beginning of the sentence.
  std::string prevStr;
  bool prevIsPunctuation = false;
  if (head != end) {
    --head;
    prevIsPunctuation = IsPunctuation(*head);
    if (prevIsPunctuation) {
      prevStr = kEmptyNodeString;
    } else {
      prevStr = CombineReadingValue((*head)->reading(),
                                    (*head)->currentUnigram().value());
    }
  } else {
    prevStr = kEmptyNodeString;
  }

  std::string anteriorStr;
  if (head != end && !prevIsPunctuation) {
    --head;
    if (IsPunctuation((*head))) {
      anteriorStr = kEmptyNodeString;
    } else {
      anteriorStr = CombineReadingValue((*head)->reading(),
                                        (*head)->currentUnigram().value());
    }
  } else {
    anteriorStr = kEmptyNodeString;
  }

  return anteriorStr + "-" + prevStr + "-" + headStr;
}

}  // namespace McBopomofo
