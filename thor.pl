#!/usr/bin/perl -w
#use File::Monitor;
use Linux::Inotify2;
use Config::File;
use Proc::Daemon;
use Getopt::Long;
use GnuPG;
use File::Basename;
use Amazon::S3;

my $configuration_file = "/usr/local/scripts/thor.cfg";
my $config_hash = Config::File::read_config_file($configuration_file);
my $uploads_dir = $config_hash->{uploads_dir};
my $log_file = $config_hash->{log_file};
my $pid_file = "/var/run/thor.pid";
my $gpg_homedir = $config_hash->{gpg_homedir};
my $gpg_recipient = $config_hash->{gpg_recipient};
my $encrypted_dir = $config_hash->{encrypted_dir};
my $archive_dir = $config_hash->{archive_dir};
my $aws_access_key_id = $config_hash->{aws_access_key_id};
my $aws_secret_access_key = $config_hash->{aws_secret_access_key};

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

    #$daemon->Init;

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

  my $result = encrypt_file($filename->fullname);
  open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  print $logfh "Result of encryption: -->" . $result . "<--\n";
  close $logfh;

  if ($result) {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      print $logfh "About to send " . $filename->fullname . ".gpg to s3\n";
      close $logfh;
  }#end if

} #end sub handle_new

sub encrypt_file {
  my $input_file = shift;
  my($filename, $filedir, $fileext) = fileparse($input_file);
  my $encrypted_file = $filename . ".gpg";
  my $encrypted_path = $encrypted_dir . "/" . $encrypted_file;

  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  print $logfh "Encrypting " . $input_file . " to " . $encrypted_path . "\n";
  close $logfh;

  my $gpg = new GnuPG(
    homedir => $gpg_homedir
  );

 
  eval {$gpg->encrypt (
    plaintext => $input_file,
    output    => $encrypted_path,
    recipient => 'john@jolet.net'
  )};

  if ($@) {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      print $logfh "Unable to encrypt  " . $input_file . " to " . $encrypted_file . "$!\n";
      close $logfh;
      return 0;
  } else {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      print $logfh "Successfully encrypted  " . $input_file . " to " . $encrypted_file . "$!\n";
      close $logfh;
  }#end else

  send_to_s3($encrypted_path);

} #end encrypt_file

sub send_to_s3 {
  my $input_file = shift;

  my($filename, $filedir, $fileext) = fileparse($input_file);

  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  print $logfh "Sending " . $input_file . " to s3...\n";
  close $logfh;

  my $s3 = Amazon::S3->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key,
          retry                 => 1
      }
  );#end new s3

  my $bucket = $s3->bucket("escrowfiles");

  my $response = $bucket->add_key_filename(
    $filename,
    $input_file,
    {
      content_type => 'application/octet-stream',
    }
  );

}#end send_to_s3
