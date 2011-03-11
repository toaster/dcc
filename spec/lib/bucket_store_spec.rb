require File.dirname(__FILE__) + '/../spec_helper'
require 'lib/bucket_store'

describe BucketStore do
  before do
    @store = BucketStore.new
  end

  it "should allow to set buckets for a project" do
    @store.set_buckets 'my_project', %w(my buckets)
  end

  it "should deliver buckets one by one" do
    @store.set_buckets 'my_project', [1, 2, 3, 4]
    @store.next_bucket('1').should == 4
    @store.next_bucket('1').should == 3
    @store.next_bucket('1').should == 2
    @store.next_bucket('1').should == 1
  end

  it "should deliver nil when no more buckets are available" do
    @store.set_buckets 'my_project', []
    @store.next_bucket('1').should == nil
    @store.next_bucket('1').should == nil
  end

  it "should deliver nil when no buckets were set" do
    @store.next_bucket('1').should == nil
    @store.next_bucket('1').should == nil
  end

  it "should be empty if no buckets were set" do
    @store.should be_empty
  end

  it "should not be empty if buckets were set" do
    @store.set_buckets 'my_project', [1, 2, 3, 4]
    @store.should_not be_empty
  end

  it "should be empty if no buckets are available" do
    @store.set_buckets 'p1', []
    @store.set_buckets 'p2', nil
    @store.set_buckets 'p3', []
    @store.should be_empty
  end

  it "should be empty if all buckets are consumed" do
    @store.set_buckets 'my_project', [1, 2, 3, 4]
    @store.next_bucket('1')
    @store.next_bucket('1')
    @store.next_bucket('1')
    @store.next_bucket('1')
    @store.should be_empty
  end

  it "should not be empty if buckets are available" do
    @store.set_buckets 'p1', []
    @store.set_buckets 'p2', [1, 2, 3]
    @store.set_buckets 'p3', []
    @store.should_not be_empty
  end

  describe "when delivering emptiness for a specific project" do
    before do
      @store.set_buckets 'p1', []
      @store.set_buckets 'p2', [1, 2, 3]
      @store.set_buckets 'p3', nil
    end

    it "should return true if project was never initialized" do
      @store.should be_empty('p4')
    end

    it "should return true if project has no buckets" do
      @store.should be_empty('p1')
      @store.should be_empty('p3')
    end

    it "should return false if project has buckets" do
      @store.should_not be_empty('p2')
    end
  end

  describe "when delivering buckets for multiple projects" do
    it "should deliver buckets from alternating projects" do
      @store.set_buckets 'p1', [11, 12]
      @store.set_buckets 'p2', [21, 22]
      @store.next_bucket('1').should == 12
      @store.next_bucket('2').should == 22
      @store.next_bucket('3').should == 11
      @store.next_bucket('4').should == 21
    end

    it "should deliver buckets from alternating projects including newly added ones" do
      @store.set_buckets 'p1', [11, 12, 13]
      @store.next_bucket('1').should == 13
      @store.set_buckets 'p2', [21, 22]
      @store.next_bucket('2').should == 22
      @store.next_bucket('3').should == 12
      @store.next_bucket('4').should == 21
      @store.next_bucket('5').should == 11
    end

    it "should deliver remaining buckets from other projects when a project has no more buckets" do
      @store.set_buckets 'p1', [11, 12, 13]
      @store.set_buckets 'p2', [21]
      @store.set_buckets 'p3', nil
      @store.next_bucket('1').should == 13
      @store.next_bucket('2').should == 21
      @store.next_bucket('3').should == 12
      @store.next_bucket('4').should == 11
    end

    it "should try to give all projects the same amount of workers" do
      @store.set_buckets 'p1', [10, 11, 12, 13, 14, 15, 16]
      @store.set_buckets 'p2', [20, 21, 22, 23, 24, 25, 26]
      @store.next_bucket('1').should == 16
      @store.next_bucket('2').should == 26
      @store.next_bucket('3').should == 15
      @store.next_bucket('4').should == 25
      @store.next_bucket('5').should == 14
      @store.next_bucket('6').should == 24

      # Zunächst bekommt p3 alle worker, um die Balance herzustellen
      @store.set_buckets 'p3', [30, 31, 32, 33, 34, 35, 36]
      @store.next_bucket('7').should == 36
      @store.next_bucket('8').should == 35
      @store.next_bucket('9').should == 34

      # Jetzt bekommt immer ein Projekt aus der Menge derer, die am wenigsten worker haben
      @store.next_bucket('10').should == 13
      @store.next_bucket('11').should == 23
      @store.next_bucket('12').should == 33

      # Freigewordene Worker gehen im Balancefall an den hergebenden …
      @store.next_bucket('12').should == 32
      @store.next_bucket('10').should == 12
      @store.next_bucket('11').should == 22

      # … ansonsten an einen aus der Menge derer, die am wenigsten worker haben
      @store.set_buckets 'p4', [41, 42, 43, 44, 45, 46]
      @store.next_bucket('10').should == 46
      @store.next_bucket('11').should == 45
      @store.next_bucket('12').should == 44
      @store.next_bucket('10').should == 43

      # wird ein Projekt reinitialisiert, fängt es wieder bei 0 an
      @store.set_buckets 'p1', [1, 2, 3, 4, 5, 6]
      @store.next_bucket('a').should == 6
      @store.next_bucket('b').should == 5
      @store.next_bucket('c').should == 4
    end
  end
end
