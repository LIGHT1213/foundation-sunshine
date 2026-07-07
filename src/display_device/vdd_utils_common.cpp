/**
 * @file vdd_utils_common.cpp
 * @brief Cross-platform portions of vdd_utils (compiled on every platform).
 *
 * The bulk of vdd_utils (named-pipe transport, ZakoVDD IOCTL dispatch,
 * DevManView actions, topology manipulation) is Windows-only and lives in
 * `vdd_utils.cpp`, which is only added to the Windows build. This file holds
 * the small set of helpers that are pure STL/Boost and are referenced from
 * the cross-platform `session.h` / `parsed_config.cpp` code paths, so they
 * must be available when building for macOS/Linux as well.
 */

#include "vdd_utils.h"

#include <boost/property_tree/json_parser.hpp>
#include <boost/property_tree/ptree.hpp>
#include <boost/uuid/name_generator_sha1.hpp>
#include <boost/uuid/uuid.hpp>
#include <boost/uuid/uuid_io.hpp>
#include <algorithm>
#include <chrono>
#include <sstream>
#include <string>
#include <unordered_map>

#include "src/config.h"
#include "src/logging.h"

namespace pt = boost::property_tree;

namespace display_device::vdd_utils {

  std::chrono::milliseconds
  calculate_exponential_backoff(int attempt) {
    auto delay = kInitialRetryDelay * (1 << attempt);
    return std::min(delay, kMaxRetryDelay);
  }

  std::string
  generate_client_guid(const std::string &identifier) {
    if (identifier.empty()) {
      return "";
    }

    // 使用SHA1 name generator确保相同标识符生成相同GUID
    static constexpr boost::uuids::uuid ns_id {};
    const auto boost_uuid = boost::uuids::name_generator_sha1 { ns_id }(
      reinterpret_cast<const unsigned char *>(identifier.c_str()),
      identifier.size());

    return "{" + boost::uuids::to_string(boost_uuid) + "}";
  }

  physical_size_t
  get_client_physical_size(const std::string &client_name) {
    if (client_name.empty()) {
      return {};
    }

    // 预定义尺寸映射表
    static const std::unordered_map<std::string, physical_size_t> size_map = {
      { "small", { 13.3f, 7.5f } },  // 小型设备：约6英寸，16:9比例
      { "medium", { 34.5f, 19.4f } },  // 中型设备：约15.6英寸，16:9比例
      { "large", { 70.8f, 39.8f } }  // 大型设备：约32英寸，16:9比例
    };

    try {
      pt::ptree clientArray;
      std::stringstream ss(config::nvhttp.clients);
      pt::read_json(ss, clientArray);

      for (const auto &client : clientArray) {
        if (client.second.get<std::string>("name", "") == client_name) {
          const std::string device_size = client.second.get<std::string>("deviceSize", "medium");
          auto it = size_map.find(device_size);
          return (it != size_map.end()) ? it->second : size_map.at("medium");
        }
      }
    }
    catch (const std::exception &e) {
      BOOST_LOG(debug) << "获取客户端物理尺寸失败: " << e.what();
    }

    return {};
  }

}  // namespace display_device::vdd_utils
