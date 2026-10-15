# frozen_string_literal: true

require_relative "../../spec_helper"

# Freezes the size error the Kubernetes and VM APIs return, through their
# real routes. The list is computed from Option::VmSizes without the
# emulated family, so an upstream size change does not break it but an
# emulated size leaking into either API does.
RSpec.describe Clover, "vm size error" do
  let(:user) { create_account }
  let(:project) { project_with_default_policy(user) }

  def expected_error(only_visible:, size: "emulated-2")
    names = Option::VmSizes.select { (!only_visible || it.visible) && it.family != "emulated" }.map(&:name)
    "\"#{size}\" is not a valid virtual machine size. Available sizes: #{names}"
  end

  before do
    login_api
    allow(Config).to receive(:kubernetes_service_project_id).and_return(Project.create(name: "UbicloudKubernetesService").id)
  end

  it "keeps the Kubernetes worker size error" do
    post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/golden", {
      version: Option.selectable_kubernetes_versions.last,
      worker_size: "emulated-2",
      worker_nodes: 1,
      cp_nodes: 1,
    }.to_json

    expect(last_response).to have_api_error(400, "Validation failed for following fields: size", {"size" => expected_error(only_visible: false)})
  end

  it "refuses every lower-tier size as a Kubernetes worker size" do
    Option::TierVmSizes.each do |size|
      post "/project/#{project.ubid}/location/#{TEST_LOCATION}/kubernetes-cluster/golden-#{size.name}", {
        version: Option.selectable_kubernetes_versions.last,
        worker_size: size.name,
        worker_nodes: 1,
        cp_nodes: 1,
      }.to_json

      expect(last_response).to have_api_error(400, "Validation failed for following fields: size", {"size" => expected_error(only_visible: false, size: size.name)})
    end
    expect(KubernetesCluster.count).to eq 0
  end

  it "keeps the VM size error" do
    post "/project/#{project.ubid}/location/#{TEST_LOCATION}/vm/golden", {
      public_key: "ssh key",
      unix_user: "ubi",
      size: "emulated-2",
    }.to_json

    expect(last_response).to have_api_error(400, "Validation failed for following fields: size", {"size" => expected_error(only_visible: true)})
  end
end
