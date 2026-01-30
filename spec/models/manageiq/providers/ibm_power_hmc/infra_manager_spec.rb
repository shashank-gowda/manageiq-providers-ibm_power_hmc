describe ManageIQ::Providers::IbmPowerHmc::InfraManager do
  it "returns the expected value for the ems_type method" do
    expect(described_class.ems_type).to eq('ibm_power_hmc')
  end

  it "returns the expected value for the description method" do
    expect(described_class.description).to eq('IBM Power HMC')
  end

  it "returns the expected value for the hostname_required? method" do
    expect(described_class.hostname_required?).to eq(true)
  end

  describe "#catalog_types" do
    let(:ems) { FactoryBot.create(:ems_ibm_power_hmc_infra) }

    it "catalog_types" do
      expect(ems.catalog_types["ibm_power_hmc"]).to eq "IBM Power HMC"
    end
  end

  describe "#parse_hmc_version" do
    let(:ems) { FactoryBot.create(:ems_ibm_power_hmc_infra) }

    context "with IBM format versions" do
      it "parses V11R1 1110 format correctly" do
        version = ems.parse_hmc_version("V11R1 1110")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("11.1.1110")
      end

      it "parses V10R2 1020 format correctly" do
        version = ems.parse_hmc_version("V10R2 1020")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("10.2.1020")
      end

      it "parses V9R1 910 format correctly" do
        version = ems.parse_hmc_version("V9R1 910")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("9.1.910")
      end

      it "parses V10R1 1010 format correctly" do
        version = ems.parse_hmc_version("V10R1 1010")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("10.1.1010")
      end

      it "parses version with extra whitespace" do
        version = ems.parse_hmc_version("  V11R1   1110  ")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("11.1.1110")
      end

      it "parses version without build number" do
        version = ems.parse_hmc_version("V11R1")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("11.1")
      end

      it "raises ArgumentError for invalid IBM format" do
        expect { ems.parse_hmc_version("VR1 1110") }.to raise_error(ArgumentError, /Invalid IBM HMC version format/)
      end

      it "raises ArgumentError for malformed IBM format" do
        expect { ems.parse_hmc_version("V11 1110") }.to raise_error(ArgumentError, /Invalid IBM HMC version format/)
      end
    end

    context "with numeric format versions" do
      it "parses standard numeric format 10.2.1030.0" do
        version = ems.parse_hmc_version("10.2.1030.0")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("10.2.1030.0")
      end

      it "parses three-part numeric format 11.1.1110" do
        version = ems.parse_hmc_version("11.1.1110")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("11.1.1110")
      end

      it "parses two-part numeric format 10.2" do
        version = ems.parse_hmc_version("10.2")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("10.2")
      end

      it "parses single numeric version 11" do
        version = ems.parse_hmc_version("11")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("11")
      end

      it "handles numeric format with whitespace" do
        version = ems.parse_hmc_version("  10.2.1030.0  ")
        expect(version).to be_a(Gem::Version)
        expect(version.to_s).to eq("10.2.1030.0")
      end
    end

    context "with version comparisons" do
      it "correctly compares IBM format versions" do
        v11 = ems.parse_hmc_version("V11R1 1110")
        v10 = ems.parse_hmc_version("V10R2 1020")
        expect(v11).to be > v10
      end

      it "correctly compares numeric format versions" do
        v11 = ems.parse_hmc_version("11.1.1110")
        v10 = ems.parse_hmc_version("10.2.1020")
        expect(v11).to be > v10
      end

      it "correctly compares mixed format versions" do
        v_ibm = ems.parse_hmc_version("V11R1 1110")
        v_numeric = ems.parse_hmc_version("11.1.1110")
        expect(v_ibm).to eq(v_numeric)
      end

      it "handles equal versions" do
        v1 = ems.parse_hmc_version("V10R2 1020")
        v2 = ems.parse_hmc_version("10.2.1020")
        expect(v1).to eq(v2)
      end

      it "handles greater than or equal comparisons" do
        v11 = ems.parse_hmc_version("V11R1 1110")
        v10 = ems.parse_hmc_version("V10R2 1020")
        threshold = ems.parse_hmc_version("V10R2 1020")
        
        expect(v11 >= threshold).to be true
        expect(v10 >= threshold).to be true
        expect(v10 > threshold).to be false
      end
    end

    context "with edge cases" do
      it "handles empty string" do
        expect { ems.parse_hmc_version("") }.to raise_error(ArgumentError)
      end

      it "handles nil converted to string" do
        expect { ems.parse_hmc_version(nil) }.to raise_error(ArgumentError)
      end

      it "handles invalid version string" do
        expect { ems.parse_hmc_version("invalid") }.to raise_error(ArgumentError)
      end

      it "handles version with letters in numeric format" do
        expect { ems.parse_hmc_version("10.2.abc") }.to raise_error(ArgumentError)
      end
    end
  end
end
