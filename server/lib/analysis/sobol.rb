#*******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2016, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER, THE UNITED STATES
# GOVERNMENT, OR ANY CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#*******************************************************************************

# Non Sorting Genetic Algorithm
class Analysis::Sobol
  include Analysis::Core
  include Analysis::R

  def initialize(analysis_id, analysis_job_id, options = {})
    defaults = {
      skip_init: false,
      run_data_point_filename: 'run_openstudio_workflow.rb',
      create_data_point_filename: 'create_data_point.rb',
      output_variables: [],
      problem: {
        random_seed: 1979,
        algorithm: {
          number_of_samples: 30,
          random_seed: 1979,
          random_seed2: 1973,
          order: 1,
          nboot: 0,
          conf: 0.95,
          type: 'sobol',
          normtype: 'minkowski',
          ppower: 2,
          objective_functions: []
        }
      }
    }.with_indifferent_access # make sure to set this because the params object from rails is indifferential
    @options = defaults.deep_merge(options)

    @analysis_id = analysis_id
    @analysis_job_id = analysis_job_id
  end

  # Perform is the main method that is run in the background.  At the moment if this method crashes
  # it will be logged as a failed delayed_job and will fail after max_attempts.
  def perform
    @analysis = Analysis.find(@analysis_id)

    # get the analysis and report that it is running
    @analysis_job = Analysis::Core.initialize_analysis_job(@analysis, @analysis_job_id, @options)

    # reload the object (which is required) because the subdocuments (jobs) may have changed
    @analysis.reload

    # create an instance for R
    @r = Rserve::Simpler.new
    Rails.logger.info 'Setting up R for Sobol Run'
    @r.converse('setwd("/mnt/openstudio")')

    # TODO: deal better with random seeds
    @r.converse("set.seed(#{@analysis.problem['random_seed']})")
    # R libraries needed for this algorithm
    @r.converse 'library(rjson)'
    @r.converse 'library(sensitivity)'

    # At this point we should really setup the JSON that can be sent to the worker nodes with everything it needs
    # This would allow us to easily replace the queuing system with rabbit or any other json based versions.

    # get the master ip address
    master_ip = ComputeNode.where(node_type: 'server').first.ip_address
    Rails.logger.info("Master ip: #{master_ip}")
    Rails.logger.info('Starting Sobol Run')

    # Quick preflight check that R, MongoDB, and Rails are working as expected. Checks to make sure
    # that the run flag is true.

    # TODO: preflight check -- need to catch this in the analysis module
    if @analysis.problem['algorithm']['order'].nil? || @analysis.problem['algorithm']['order'] == 0
      fail 'Value for order was not set or equal to zero (must be 1 or greater)'
    end

    if @analysis.problem['algorithm']['conf'].nil? || @analysis.problem['algorithm']['conf'] == 0
      fail 'Value for conf was not set or equal to zero (must be 1 or greater)'
    end

    if @analysis.problem['algorithm']['number_of_samples'].nil? || @analysis.problem['algorithm']['number_of_samples'] == 0
      fail 'Must have number of samples to discretize the parameter space'
    end

    pivot_array = Variable.pivot_array(@analysis.id, @r)
    Rails.logger.info "pivot_array: #{pivot_array}"
    selected_variables = Variable.variables(@analysis.id)
    Rails.logger.info "Found #{selected_variables.count} variables to perturb"

    # discretize the variables using the LHS sampling method
    @r.converse("print('starting lhs to get min/max')")
    Rails.logger.info 'starting lhs to discretize the variables'

    lhs = Analysis::R::Lhs.new(@r)
    Rails.logger.info "Setting R base random seed to #{@analysis.problem['random_seed']}"
    @r.converse("set.seed(#{@analysis.problem['algorithm']['random_seed']})")
    samples, var_types, mins_maxes, var_names = lhs.sample_all_variables(selected_variables, @analysis.problem['algorithm']['number_of_samples'])
    Rails.logger.info "Setting R base random seed to #{@analysis.problem['random_seed2']}"
    @r.converse("set.seed(#{@analysis.problem['algorithm']['random_seed2']})")
    samples2, var_types2, mins_maxes2, var_names2 = lhs.sample_all_variables(selected_variables, @analysis.problem['algorithm']['number_of_samples'])

    if samples.empty? || samples.size <= 1
      Rails.logger.info 'No variables were passed into the options, therefore exit'
      fail "Must have more than one variable to run algorithm.  Found #{samples.size} variables"
    end

    # Result of the parameter space will be column vectors of each variable
    Rails.logger.info "Samples are #{samples}"
    Rails.logger.info "Samples2 are #{samples2}"

    Rails.logger.info "mins_maxes: #{mins_maxes}"
    Rails.logger.info "var_names: #{var_names}"
    Rails.logger.info "var_names2: #{var_names2}"
    Rails.logger.info("variable types are #{var_types}")

    # Initialize some variables that are in the rescue/ensure blocks
    cluster = nil
    process = nil
    begin
      # Start up the cluster and perform the analysis
      cluster = Analysis::R::Cluster.new(@r, @analysis.id)
      unless cluster.configure(master_ip)
        fail 'could not configure R cluster'
      end

      # Initialize each worker node
      worker_ips = ComputeNode.worker_ips
      Rails.logger.info "Worker node ips #{worker_ips}"

      Rails.logger.info 'Running initialize worker scripts'
      unless cluster.initialize_workers(worker_ips, @analysis.id)
        fail 'could not run initialize worker scripts'
      end

      # Before kicking off the Analysis, make sure to setup the downloading of the files child process
      process = Analysis::Core::BackgroundTasks.start_child_processes

      worker_ips = ComputeNode.worker_ips
      Rails.logger.info "Found the following good ips #{worker_ips}"

      if cluster.start(worker_ips)
        Rails.logger.info "Cluster Started flag is #{cluster.started}"
        # gen is the number of generations to calculate
        # varNo is the number of variables (ncol(vars))
        # popSize is the number of sample points in the variable (nrow(vars))
        @r.command(master_ips: master_ip, ips: worker_ips[:worker_ips].uniq, vars: samples.to_dataframe, vars2: samples2.to_dataframe, vartypes: var_types, varnames: var_names, mins: mins_maxes[:min], maxes: mins_maxes[:max],
                   order: @analysis.problem['algorithm']['order'], nboot: @analysis.problem['algorithm']['nboot'],
                   type: @analysis.problem['algorithm']['type'], conf: @analysis.problem['algorithm']['conf'],
                   normtype: @analysis.problem['algorithm']['normtype'], ppower: @analysis.problem['algorithm']['ppower'],
                   objfun: @analysis.problem['algorithm']['objective_functions'],
                   mins: mins_maxes[:min], maxes: mins_maxes[:max]) do
          %{
            clusterEvalQ(cl,library(RMongo))
            clusterEvalQ(cl,library(rjson))
            clusterEvalQ(cl,library(R.utils))

            print(paste("order:",order))
            print(paste("nboot:",nboot))
            print(paste("conf:",conf))
            print(paste("type:",type))

            objDim <- length(objfun)
            print(paste("objDim:",objDim))
            print(paste("normtype:",normtype))
            print(paste("ppower:",ppower))

            print(paste("min:",mins))
            print(paste("max:",maxes))

            clusterExport(cl,"objDim")
            clusterExport(cl,"normtype")
            clusterExport(cl,"ppower")

            # for (i in 1:ncol(vars)){
              # vars[,i] <- sort(vars[,i])
            # }
            print(paste("vartypes:",vartypes))
            print(paste("varnames:",varnames))

            varfile <- function(x){
              if (!file.exists("/mnt/openstudio/analysis_#{@analysis.id}/varnames.json")){
               write.table(x, file="/mnt/openstudio/analysis_#{@analysis.id}/varnames.json", quote=FALSE,row.names=FALSE,col.names=FALSE)
              }
            }

            clusterExport(cl,"varfile")
            clusterExport(cl,"varnames")
            clusterEvalQ(cl,varfile(varnames))

            #f(x) takes a UUID (x) and runs the datapoint
            f <- function(x){
              mongo <- mongoDbConnect("#{Analysis::Core.database_name}", host="#{master_ip}", port=27017)
              flag <- dbGetQueryForKeys(mongo, "analyses", '{_id:"#{@analysis.id}"}', '{run_flag:1}')
              if (flag["run_flag"] == "false" ){
                stop(options("show.error.messages"=FALSE),"run flag is not TRUE")
              }
              dbDisconnect(mongo)

              ruby_command <- "cd /mnt/openstudio && #{RUBY_BIN_DIR}/bundle exec ruby"
              if ("#{@analysis.use_shm}" == "true"){
                y <- paste(ruby_command," /mnt/openstudio/simulate_data_point.rb -a #{@analysis.id} -u ",x," -x #{@options[:run_data_point_filename]} --run-shm",sep="")
              } else {
                y <- paste(ruby_command," /mnt/openstudio/simulate_data_point.rb -a #{@analysis.id} -u ",x," -x #{@options[:run_data_point_filename]}",sep="")
              }
              #print(paste("R is calling system command as:",y))
              z <- system(y,intern=TRUE)
              #print(paste("R returned system call with:",z))
              return(z)
            }
            clusterExport(cl,"f")

            #g(x) such that x is vector of variable values,
            #           create a data_point from the vector of variable values x and return the new data point UUID
            #           create a UUID for that data_point and put in database
            #           call f(u) where u is UUID of data_point
            g <- function(x){
              force(x)
              #print(paste("x:",x))
              ruby_command <- "cd /mnt/openstudio && #{RUBY_BIN_DIR}/bundle exec ruby"
              # convert the vector to comma separated values
              w = paste(x, collapse=",")

              y <- paste(ruby_command," /mnt/openstudio/#{@options[:create_data_point_filename]} -a #{@analysis.id} -v ",w, sep="")
              #print(paste("g(y):",y))
              z <- system(y,intern=TRUE)
              j <- length(z)
              z

              # Call the simulate data point method
            if (as.character(z[j]) == "NA") {
              cat("UUID is NA \n");
              NAvalue <- 1.0e19
              return(NAvalue)
            } else {
              try(f(z[j]), silent = TRUE)

              data_point_directory <- paste("/mnt/openstudio/analysis_#{@analysis.id}/data_point_",z[j],sep="")

              # save off the variables file (can be used later if number of vars gets too long)
              write.table(x, paste(data_point_directory,"/input_variables_from_r.data",sep=""),row.names = FALSE, col.names = FALSE)

              # read in the results from the objective function file
              object_file <- paste(data_point_directory,"/objectives.json",sep="")
              json <- NULL
              try(json <- fromJSON(file=object_file), silent=TRUE)

              if (is.null(json)) {
                obj <- 1.0e19
              } else {
                obj <- NULL
                objvalue <- NULL
                objtarget <- NULL
                sclfactor <- NULL

                for (i in 1:objDim){
                  objfuntemp <- paste("objective_function_",i,sep="")
                  if (json[objfuntemp] != "NULL"){
                    objvalue[i] <- as.numeric(json[objfuntemp])
                  } else {
                    objvalue[i] <- 1.0e19
                    cat(data_point_directory," Missing ", objfuntemp,"\n");
                  }
                  objfuntargtemp <- paste("objective_function_target_",i,sep="")
                  if (json[objfuntargtemp] != "NULL"){
                    objtarget[i] <- as.numeric(json[objfuntargtemp])
                  } else {
                    objtarget[i] <- 0.0
                  }
                  scalingfactor <- paste("scaling_factor_",i,sep="")
                  sclfactor[i] <- 1.0
                  if (json[scalingfactor] != "NULL"){
                    sclfactor[i] <- as.numeric(json[scalingfactor])
                    if (sclfactor[i] == 0.0) {
                      print(paste(scalingfactor," is ZERO, overwriting\n"))
                      sclfactor[i] = 1.0
                    }
                  } else {
                    sclfactor[i] <- 1.0
                  }
                }
                print(paste("Objective function results are:",objvalue))
                print(paste("Objective function targets are:",objtarget))
                print(paste("Objective function scaling factors are:",sclfactor))

                objvalue <- objvalue / sclfactor
                objtarget <- objtarget / sclfactor
                obj <- force(eval(dist(rbind(objvalue,objtarget),method=normtype,p=ppower)))

                print(paste("Objective function Norm:",obj))

                mongo <- mongoDbConnect("#{Analysis::Core.database_name}", host="#{master_ip}", port=27017)
                flag <- dbGetQueryForKeys(mongo, "analyses", '{_id:"#{@analysis.id}"}', '{exit_on_guideline14:1}')
                dbDisconnect(mongo)
              }
              return(as.numeric(obj))
            }
            }
            clusterExport(cl,"g")

            results <- NULL
            if (type == "sobol") {
            m <- sobol(model=NULL, X1=vars, X2=vars2, order=order, nboot=nboot, conf=conf)
            } else if (type == "2002") {
            m <- sobol2002(model=NULL, X1=vars, X2=vars2, nboot=nboot, conf=conf)
            } else if (type == "2007") {
            m <- sobol2007(model=NULL, X1=vars, X2=vars2, nboot=nboot, conf=conf)
            } else if (type == "jansen") {
            m <- soboljansen(model=NULL, X1=vars, X2=vars2, nboot=nboot, conf=conf)
            } else if (type == "mara") {
            m <- sobolmara(model=NULL, X1=vars)
            } else if (type == "martinez") {
            m <- sobolmartinez(model=NULL, X1=vars, X2=vars2, nboot=nboot, conf=conf)
            } else { print("unknown method")}
            print(paste("m:", m))
            print(paste("m$X:", m$X))
            m1 <- as.list(data.frame(t(m$X)))
            print(paste("m1:", m1))
            results <- clusterApplyLB(cl, m1, g)
            print(mode(as.numeric(results)))
            print(is.list(results))
            print(paste("results:", as.numeric(results)))
            tell(m,as.numeric(results))
            print(m)

            # var_mu <- rep(0, ncol(vars))
            # var_mu_star <- var_mu
            # var_sigma <- var_mu
            # for (i in 1:ncol(vars)){
              # var_mu[i] <- mean(m$ee[,i])
              # var_mu_star[i] <- mean(abs(m$ee[,i]))
              # var_sigma[i] <- sd(m$ee[,i])
            # }
            # answer <- paste('{',paste('"',gsub(".","|",varnames, fixed=TRUE),'":','{"var_mu": ',var_mu,',"var_mu_star": ',var_mu_star,',"var_sigma": ',var_sigma,'}',sep='', collapse=','),'}',sep='')
            # write.table(answer, file="/mnt/openstudio/analysis_#{@analysis.id}/morris.json", quote=FALSE,row.names=FALSE,col.names=FALSE)

            save(m, file="/mnt/openstudio/analysis_#{@analysis.id}/m.R")
          }
        end
      else
        fail 'could not start the cluster (most likely timed out)'
      end

    rescue => e
      log_message = "#{__FILE__} failed with #{e.message}, #{e.backtrace.join("\n")}"
      Rails.logger.error log_message
      @analysis.status_message = log_message
      @analysis.save!
      @analysis_job.status = 'completed'
      @analysis_job.save!
      @analysis.reload
      @analysis.save!
    ensure
      # ensure that the cluster is stopped
      cluster.stop if cluster

      # Kill the downloading of data files process
      Rails.logger.info('Ensure block of analysis cleaning up any remaining processes')
      process.stop if process

      Rails.logger.info 'Running finalize worker scripts'
      unless cluster.finalize_workers(worker_ips, @analysis.id)
        fail 'could not run finalize worker scripts'
      end

      # Post process the results and jam into the database
      best_result_json = "/mnt/openstudio/analysis_#{@analysis.id}/best_result.json"
      if File.exist? best_result_json
        begin
          Rails.logger.info('read best result json')
          temp2 = File.read(best_result_json)
          temp = JSON.parse(temp2, symbolize_names: true)
          Rails.logger.info("temp: #{temp}")
          @analysis.results[@options[:analysis_type]]['best_result'] = temp
          @analysis.save!
          Rails.logger.info("analysis: #{@analysis.results}")
        rescue => e
          Rails.logger.error 'Could not save post processed results for bestresult.json into the database'
        end
      end

      # Do one last check if there are any data points that were not downloaded
      Rails.logger.info('Trying to download any remaining files from worker nodes')
      @analysis.finalize_data_points

      # Only set this data if the analysis was NOT called from another analysis
      unless @options[:skip_init]
        @analysis_job.end_time = Time.now
        @analysis_job.status = 'completed'
        @analysis_job.save!
        @analysis.reload
      end
      @analysis.save!

      Rails.logger.info "Finished running analysis '#{self.class.name}'"
    end
  end

  # Since this is a delayed job, if it crashes it will typically try multiple times.
  # Fix this to 1 retry for now.
  def max_attempts
    1
  end
end
