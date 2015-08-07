#!/usr/bin/perl -w
#use File::Monitor;
use Linux::Inotify2;
use Config::File;
use Proc::Daemon;
use Getopt::Long;

my $configuration_file = "/usr/local/scripts/thor.cfg";
my $config_hash = Config::File::read_config_file($configuration_file);
my $uploads_dir = $config_hash->{uploads_dir};
my $log_file = $config_hash->{log_file};
my $pid_file = "/var/run/thor.pid";

my $daemon = Proc::Daemon->new(
  pid_file     => $pid_file,
  work_dir     => '/usr/local/scripts',
  child_STDERR => $log_file,
  child_STDERR => $log_file
);

my $pid = $daemon->Status($pid_file);

GetOptions(
  "start"  => \&run,
  "stop"   => \&stop,
  "status" => \&status
)
or die("Error in command line arguments\n");

sub stop {
  if ($pid) {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    print $logfh "Stopping thor with pid $pid...\n";
    close $logfh;
    $daemon->Kill_Daemon($pid_file);
  } else {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    print $logfh "Thor already stopped...\n";
    close $logfh;
  }#end if
}#end sub stop

sub status {
  if ($pid) {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    print $logfh "Running thor with pid $pid...\n";
    close $logfh;
  }#end if
}#end sub status

sub run {
  if (!$pid) {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      print $logfh "About to initialize thor daemon...\n";
      close $logfh;

    $daemon->Init;

      my $notification = new Linux::Inotify2 or die "unable to watch $uploads_dir: $!";
      $notification->watch($uploads_dir, IN_CLOSE_WRITE, \&handle_new);
      close $logfh;

    while (1) {
      $notification->poll;
    }
  } else {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    print $logfh "Already running with pid $pid\n";
    close $logfh;
  }#end if
}#end sub run

sub handle_new {
  my $filename = shift;
  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  print $logfh "Found " . $filename->fullname . "\n";
  close $logfh;
} #end sub handle_new
