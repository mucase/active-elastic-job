require "action_dispatch"

module ActiveElasticJob
  module Rack
    # This middleware intercepts requests which are sent by the SQS daemon
    # running in {Amazon Elastic Beanstalk worker environments}[http://docs.aws.amazon.com/elasticbeanstalk/latest/dg/using-features-managing-env-tiers.html].
    # It does this by looking at the +User-Agent+ header.
    # Requesets from the SQS daemon are handled in two alternative cases:
    #
    # (1) the processed SQS message was originally triggered by a periodic task
    # supported by Elastic Beanstalk's Periodic Task feature
    #
    # (2) the processed SQS message was queued by this gem representing an active job.
    # In this case it verifies the digest which is sent along with a legit SQS
    # message, and passed as an HTTP header in the resulting request.
    # The digest is based on Rails' +secrets.secret_key_base+.
    # Therefore, the application running in the web environment, which generates
    # the digest, and the application running in the worker
    # environment, which verifies the digest, have to use the *same*
    # +secrets.secret_key_base+ setting.
    class SqsMessageConsumer
      OK_RESPONSE = [ '200'.freeze, { 'Content-Type'.freeze => 'text/plain'.freeze }, [ 'OK'.freeze ] ]
      FORBIDDEN_RESPONSE = [
        '403'.freeze,
        { 'Content-Type'.freeze => 'text/plain'.freeze },
        [ 'Request forbidden!'.freeze ]
      ]

      # 172.17.0.x is the default for Docker
      # 172.18.0.x is the default for the bridge network of Docker Compose
      DOCKER_HOST_IP = /172.1(7|8).0.\d+/.freeze

      def initialize(app) #:nodoc:
        @app = app
      end

      def call(env) #:nodoc:
        request = ActionDispatch::Request.new env
        # Rails.logger.info "RUNNING job call1 with body: #{JSON.load(request.body)}"
        if enabled? && aws_sqsd?(request)
          unless request.local? || sent_from_docker_host?(request)
            return FORBIDDEN_RESPONSE
          end
          # Rails.logger.info "RUNNING job call2 body: #{JSON.load(request.body)}"
          if periodic_task?(request)
            execute_periodic_task(request)
            return OK_RESPONSE
          else # originates_from_gem?(request)
            begin
              execute_job(request)
            rescue ActiveElasticJob::MessageVerifier::InvalidDigest => e
              return FORBIDDEN_RESPONSE
            end
            return OK_RESPONSE
          end
        end
        @app.call(env)
      end

      private

      def enabled?
        Rails.application.config.active_elastic_job.process_jobs == true
      end

      def verify!(request)
        @verifier ||= ActiveElasticJob::MessageVerifier.new(secret_key_base)
        digest = request.headers['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'.freeze]
        message = request.body_stream.read
        request.body_stream.rewind
        @verifier.verify!(message, digest)
      end

      def secret_key_base
        config.secret_key_base
      end

      def config
        Rails.application.config.active_elastic_job
      end

      def aws_sqsd?(request)
        # Does not match against a Regexp
        # in order to avoid performance penalties.
        # Instead performs a simple string comparison.
        # Benchmark runs showed an performance increase of
        # up to 40%
        current_user_agent = request.headers['User-Agent'.freeze]
        return (current_user_agent.present? &&
          current_user_agent.size >= 'aws-sqsd'.freeze.size &&
          current_user_agent[0..('aws-sqsd'.freeze.size - 1)] == 'aws-sqsd'.freeze)
      end

      def sqsd?(request)
        # Does not match against a Regexp
        # in order to avoid performance penalties.
        # Instead performs a simple string comparison.
        # Benchmark runs showed an performance increase of
        # up to 40%
        current_user_agent = request.headers['User-Agent'.freeze]
        return (current_user_agent.present? &&
          current_user_agent.size >= 'sqsd'.freeze.size &&
          current_user_agent[0..('sqsd'.freeze.size - 1)] == 'sqsd'.freeze)
      end

      def periodic_tasks_route
        @periodic_tasks_route ||= config.periodic_tasks_route
      end

      def periodic_task?(request)
        !request.fullpath.nil? && request.fullpath[0..(periodic_tasks_route.size - 1)] == periodic_tasks_route
      end

      def execute_job(request)
        # verify!(request)
        # Rails.logger.info "RUNNING job execute_job body: #{JSON.load(request.body)}"
        job = JSON.load(request.body)
        ActiveJob::Base.execute(job)
      end

      def execute_periodic_task(request)
        job_name = request.headers['X-Aws-Sqsd-Taskname']
        job = job_name.constantize.new
        job.perform_now
      end

      def originates_from_gem?(request)
        if request.headers['HTTP_X_AWS_SQSD_ATTR_ORIGIN'.freeze] == ActiveElasticJob::ACRONYM
          return true
        elsif request.headers['HTTP_X_AWS_SQSD_ATTR_MESSAGE_DIGEST'.freeze] != nil
          return true
        else
          return false
        end
      end

      def sent_from_docker_host?(request)
        app_runs_in_docker_container? && ip_originates_from_docker?(request)
      end

      def ip_originates_from_docker?(request)
        (request.remote_ip =~ DOCKER_HOST_IP).present? or (request.remote_addr =~ DOCKER_HOST_IP).present?
      end

      def app_runs_in_docker_container?
        (`[ -f /proc/1/cgroup ] && cat /proc/1/cgroup` =~ /(ecs|docker)/).present?
      end
    end
  end
end
