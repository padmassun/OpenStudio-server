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

class DataPointsController < ApplicationController
  # GET /data_points
  # GET /data_points.json
  def index
    @data_points = DataPoint.all

    respond_to do |format|
      format.html # index.html.erb
      format.json { render json: @data_points }
    end
  end

  # GET /data_points/1
  # GET /data_points/1.json
  def show
    @data_point = DataPoint.find(params[:id])
    respond_to do |format|
      if @data_point
        format.html do
          exclude_fields = [:_id, :output, :password, :values]
          @table_data = @data_point.as_json(except: exclude_fields)

          logger.info('Cleaning up the log files')
          if @table_data['sdp_log_file']
            @table_data['sdp_log_file'] = @table_data['sdp_log_file'].join('</br>').html_safe
          end

          @data_point.set_variable_values ? @set_variable_values = @data_point.set_variable_values : @set_variable_values = []
        end

        format.json do
          @data_point = @data_point.as_json
          @data_point['set_variable_values_names'] = {}
          @data_point['set_variable_values_display_names'] = {}
          @data_point['set_variable_values'].each do |k, v|
            var = Variable.find(k)
            if var
              new_key = var ? var.name : k
              new_display_key = var ? var.display_name : k
              @data_point['set_variable_values_names'][new_key] = v
              @data_point['set_variable_values_display_names'][new_display_key] = v
            end
          end

          # look up the objective functions and report
          # @data_point['objective_function_results'] = {}

          render json: { data_point: @data_point }
        end
      else
        format.html { redirect_to projects_path, notice: 'Could not find datapoint' }
        format.json { render json: { error: 'No Datapoint' }, status: :unprocessable_entity }
      end
    end
  end

  alias_method :show_full, :show

  def status
    # The name :jobs is legacy based on how PAT queries the data points. Should we alias this to status?
    only_fields = [:status, :status_message, :download_status, :analysis_id]
    dps = params[:status] ? DataPoint.where(status: params[:jobs]).only(only_fields) : DataPoint.all.only(only_fields)

    respond_to do |format|
      #  format.html # new.html.erb
      format.json do
        render json: {
          data_points: dps.map do |dp|
            {
              _id: dp.id,
              id: dp.id,
              analysis_id: dp.analysis_id,
              status: dp.status,
              final_message: dp.status_message,
              download_status: dp.download_status
            }
          end
        }
      end
    end
  end

  # GET /data_points/new
  # GET /data_points/new.json
  def new
    @data_point = DataPoint.new

    respond_to do |format|
      format.html # new.html.erb
      format.json { render json: @data_point }
    end
  end

  # GET /data_points/1/edit
  def edit
    @data_point = DataPoint.find(params[:id])
  end

  # POST /data_points
  # POST /data_points.json
  def create
    analysis_id = params[:analysis_id]
    params[:data_point][:analysis_id] = analysis_id

    @data_point = DataPoint.new(params[:data_point])

    respond_to do |format|
      if @data_point.save!
        format.html { redirect_to @data_point, notice: 'Data point was successfully created.' }
        format.json { render json: @data_point, status: :created, location: @data_point }
      else
        format.html { render action: 'new' }
        format.json { render json: @data_point.errors, status: :unprocessable_entity }
      end
    end
  end

  # POST batch_upload.json
  def batch_upload
    analysis_id = params[:analysis_id]
    logger.info('parsing in a batched file upload')

    uploaded_dps = 0
    saved_dps = 0
    error = false
    error_message = ''
    if params[:data_points]
      uploaded_dps = params[:data_points].count
      logger.info "received #{uploaded_dps} points"
      params[:data_points].each do |dp|
        # This is the old format that can be deprecated when OpenStudio V1.1.3 is released
        dp[:analysis_id] = analysis_id # need to add in the analysis id to each datapoint

        @data_point = DataPoint.new(dp)
        if @data_point.save!
          saved_dps += 1
        else
          error = true
          error_message += "could not proccess #{@data_point.errors}"
        end
      end
    end

    respond_to do |format|
      logger.info("error flag was set to #{error}")
      if !error
        format.json { render json: "Created #{saved_dps} datapoints from #{uploaded_dps} uploaded.", status: :created, location: @data_point }
      else
        format.json { render json: error_message, status: :unprocessable_entity }
      end
    end
  end

  # PUT /data_points/1
  # PUT /data_points/1.json
  def update
    @data_point = DataPoint.find(params[:id])

    respond_to do |format|
      if @data_point.update_attributes(params[:data_point])
        format.html { redirect_to @data_point, notice: 'Data point was successfully updated.' }
        format.json { head :no_content }
      else
        format.html { render action: 'edit' }
        format.json { render json: @data_point.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /data_points/1
  # DELETE /data_points/1.json
  def destroy
    @data_point = DataPoint.find(params[:id])
    analysis_id = @data_point.analysis
    @data_point.destroy

    respond_to do |format|
      format.html { redirect_to analysis_path(analysis_id) }
      format.json { head :no_content }
    end
  end

  def download
    @data_point = DataPoint.find(params[:id])

    data_point_zip_data = File.read(@data_point.openstudio_datapoint_file_name)
    send_data data_point_zip_data, filename: File.basename(@data_point.openstudio_datapoint_file_name), type: 'application/zip; header=present', disposition: 'attachment'
  end

  def download_reports
    @data_point = DataPoint.find(params[:id])

    remote_filename_reports = @data_point.openstudio_datapoint_file_name.gsub('.zip', '_reports.zip')
    data_point_zip_data = File.read(remote_filename_reports)
    send_data data_point_zip_data, filename: File.basename(remote_filename_reports), type: 'application/zip; header=present', disposition: 'attachment'
  end

  # Render an openstudio reporting measure's HTML report. This method has protection around which file to load.
  # It expects the file to be in the reports directory of the data point. If the user try to navigate the file system
  # the File.basename method will remove that.
  def view_report
    # construct the path to the report based on the routs
    @data_point = DataPoint.find(params[:id])

    # remove any preceding .. because an attacker could try and traverse the file system
    file = File.basename(params[:file])
    file_str = "/mnt/openstudio/analysis_#{@data_point.analysis.id}/data_point_#{@data_point.id}/reports/#{file}"

    if File.exist? file_str
      render file: file_str, layout: false
    else
      respond_to do |format|
        format.html { redirect_to @data_point, notice: "Could not find file #{file_str}" }
      end
    end
  end

  def dencity
    @data_point = DataPoint.find(params[:id])

    dencity = nil
    if @data_point
      # reformat the data slightly to get a concise view of the data
      dencity = {}

      # instructions for building the inputs
      measure_instances = []
      if @data_point.analysis['problem']
        if @data_point.analysis['problem']['workflow']
          @data_point.analysis['problem']['workflow'].each_with_index do |wf, _index|
            m_instance = {}
            m_instance['uri'] = 'https://bcl.nrel.gov or file:///local'
            m_instance['id'] = wf['measure_definition_uuid']
            m_instance['version_id'] = wf['measure_definition_version_uuid']

            if wf['arguments']
              m_instance['arguments'] = {}
              if wf['variables']
                wf['variables'].each do |var|
                  m_instance['arguments'][var['argument']['name']] = @data_point.set_variable_values[var['uuid']]
                end
              end

              wf['arguments'].each do |arg|
                m_instance['arguments'][arg['name']] = arg['value']
              end
            end

            measure_instances << m_instance
          end
        end
      end

      dencity[:measure_instances] = measure_instances

      # Don't use this old method.  Instead get the dencity reporting variables from the metadata_id flag
      # dencity[:structure] = @data_point[:results]['dencity_reports']

      # Grab all the variables that have defined a measure ID and pull out the results
      vars = @data_point.analysis.variables.where(:metadata_id.exists => true, :metadata_id.ne => '')
             .order_by(:name.asc).as_json(only: [:name, :metadata_id])

      dencity[:structure] = {}
      vars.each do |v|
        a, b = v['name'].split('.')
        logger.info "#{v[:metadata_id]} had #{a} and #{b}"

        if dencity[:structure][v['metadata_id']].present?
          logger.error "DEnCity variable '#{v['metadata_id']} is already defined in output as #{a}:#{b}"
        end

        if @data_point[:results][a].present? && @data_point[:results][a][b].present?
          dencity[:structure][v['metadata_id']] = @data_point[:results][a][b]
        else
          logger.warn 'could not find result'
          dencity[:structure][v['metadata_id']] = nil
        end
      end
    end

    respond_to do |format|
      if dencity
        format.json { render json: dencity.to_json }
      else
        format.json { render json: { error: 'Could not format data point into DEnCity view' }, status: :unprocessable_entity }
      end
    end
  end
end
