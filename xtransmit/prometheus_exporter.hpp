#pragma once

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace httplib
{
class Server;
}

namespace xtransmit
{

namespace socket
{
class isocket;
class srt;
}

namespace metrics
{
class validator;
}

namespace prometheus
{

class exporter
{
public:
    exporter(
        int port,
        const std::string& direction);

    ~exporter();

    exporter(const exporter&) = delete;
    exporter& operator=(const exporter&) = delete;

    void start();
    void stop();

    void add_socket(
        const std::shared_ptr<socket::isocket>& sock);

    void remove_socket(int socket_id);

    void add_metrics_validator(
    const std::shared_ptr<socket::isocket>& sock,
    const std::shared_ptr<metrics::validator>& validator);

void remove_metrics_validator(int socket_id);

private:
    std::string render_metrics();

private:
    int         m_port;
    std::string m_direction;

    std::unique_ptr<httplib::Server> m_server;
    std::thread                      m_thread;

    std::mutex m_socket_mutex;

    std::map<
        int,
        std::shared_ptr<socket::srt>>
        m_sockets;

    std::mutex m_metrics_mutex;

    std::map<
	int,
	std::shared_ptr<metrics::validator>>
	m_metrics_validators;

};

} // namespace prometheus
} // namespace xtransmit
