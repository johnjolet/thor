#!/usr/bin/perl -w
#--- Set up included modules
use Linux::Inotify2;
use Config::File;
use Proc::Daemon;
use Getopt::Long;
use GnuPG;
use File::Basename;
use File::Copy;
use Amazon::S3;

#--- set up global vars and stuff
my $configuration_file = "/usr/local/scripts/thor.cfg";
my $config_hash = Config::File::read_config_file($configuration_file);
my $uploads_dir = $config_hash->{uploads_dir};
my $log_file = $config_hash->{log_file};
my $pid_file = "/var/run/thor.pid";
my $gpg_homedir = $config_hash->{gpg_homedir};
my $gpg_recipient = $config_hash->{gpg_recipient};
my $encrypted_dir = $config_hash->{encrypted_dir};
my $archived_dir = $config_hash->{archive_dir};
my $aws_access_key_id = $config_hash->{aws_access_key_id};
my $aws_secret_access_key = $config_hash->{aws_secret_access_key};

#--- set up to be a daemon
my $daemon = Proc::Daemon->new(
  pid_file     => $pid_file,
  work_dir     => '/usr/local/scripts',
  child_STDERR => $log_file,
  child_STDERR => $log_file
);

my $pid = $daemon->Status($pid_file);

#--- find out how we were called
GetOptions(
  "start"  => \&run,
  "stop"   => \&stop,
  "status" => \&status
)
or die("Error in command line arguments\n");

#-- this stops the daemon, if we're running
sub stop {
  if ($pid) {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    my $timestamp = localtime(time);
    print $logfh "[$timestamp] Stopping thor with pid $pid...\n";
    close $logfh;
    $daemon->Kill_Daemon($pid_file);
  } else {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    $timestamp = localtime(time);
    print $logfh "[$timestamp] Thor already stopped...\n";
    close $logfh;
  }#end if
}#end sub stop

#--- finds out if we're running, and if so, what's our PID
sub status {
  if ($pid) {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    my $timestamp = localtime(time);
    print $logfh "[$timestamp] Running thor with pid $pid...\n";
    close $logfh;
    print "[$timestamp] Running thor with pid $pid...\n";
  }#end if
}#end sub status

#--- the heart of the matter...now we're gonna start up
sub run {
  if (!$pid) {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      my $timestamp = localtime(time); 
      print $logfh "[$timestamp] About to initialize thor daemon...\n";
      close $logfh;

#--- this is the line that actually makes us a daemon....
    $daemon->Init;

#--- watch the uploads dir for any changes, then call the sub handle_new
      my $notification = new Linux::Inotify2 or die "unable to watch $uploads_dir: $!";
      $notification->watch($uploads_dir, IN_CLOSE_WRITE, \&handle_new);

#--- while 1==1, spin on a Inotify2 poll...poll the kernel for filesystem changes
#    note that one a change is detected, the callback above is run...if we need to go multi-thread,
#    that should be the start of the child thread
    while (1) {
      $notification->poll;
    }
  } else {
    open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
    $timestamp = localtime(time);
    print $logfh "[$timestamp] Already running with pid $pid\n";
    close $logfh;
  }#end if
}#end sub run

#--- if we got here, a new file, or changed file, has been detected
sub handle_new {
  my $filename = shift;
  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  my $timestamp = localtime(time);
  print $logfh "[$timestamp] Found " . $filename->fullname . "\n";
  close $logfh;

#--- call the encrypt_file subroutine with the filename of the full path to the file as an argument
#    note that subsequent processing steps are "chained" or called from the preceding step, since
#    this is a highly serial process.  the return codes are percolated up back to here...so a success
#    here means ALL steps succeeded, while a failure means ONE step failed, not necessarily the encryption step
  my $result = encrypt_file($filename->fullname);
  open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  #print $logfh "Result of encryption: -->" . $result . "<--\n";
  close $logfh;

#--- if all steps succeeded, it's safe to delete the source file.  otherwise, we leave it
#    for reprocessing and troubleshooting purposes
  if ($result) {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Processing of " . $filename->fullname . " successful\n";
      close $logfh;
      unlink $filename->fullname or die "Could not unlink $filename->fullname: $!";
  } else {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Unable to encrypt  " . $filename->fullname . " $! or some other errors occurred\n";
      close $logfh;
      return 0;
  }#end if

} #end sub handle_new

#--- encrypt the file with gpg, then following steps if that succeeded
sub encrypt_file {
  my $input_file = shift;

#--- we're passed a full path, so we need the filename by itself for later steps
#    this strips off the path portions and leaves us with just the name
  my($filename, $filedir, $fileext) = fileparse($input_file);
  my $encrypted_file = $filename . ".gpg";

#--- so we know where the encrypted file needs to land from the config file
#    and that CANNOT be the same directory as the source directory, or we will recurse like mad
  my $encrypted_path = $encrypted_dir . "/" . $encrypted_file;

  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  my $timestamp = localtime(time);
  print $logfh "[$timestamp] Encrypting " . $input_file . " to " . $encrypted_path . "\n";
  close $logfh;

#--- set up the gpg stuff.  the homedir gives us the keychain, which will be used with the
#    recipient argument later to encrypt asymmetrically with the recipient's key
  my $gpg = new GnuPG(
    homedir => $gpg_homedir
  );

 
#--- this does the actual encryption
  eval {$gpg->encrypt (
    plaintext => $input_file,
    output    => $encrypted_path,
    recipient => $gpg_recipient
  )};

#--- this gpg module is kinda weird.  it will return the status in $@
  if ($@) {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Unable to encrypt  " . $input_file . " to " . $encrypted_file . "$!\n";
      close $logfh;
      return 0;
  } else {
      open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Successfully encrypted  " . $input_file . " to " . $encrypted_file . "\n";
      close $logfh;
  }#end else

#--- if we got here, the encryption must have succeeded, so let's send the encrypted file to s3
  my $response = send_to_s3($encrypted_path);
  return $response;
} #end encrypt_file

#--- send the file to s3
sub send_to_s3 {
  my $input_file = shift;

#--- we're sent the full filepath, we just need the filename for later
  my($filename, $filedir, $fileext) = fileparse($input_file);

  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  my $timestamp = localtime(time);
  print $logfh "[$timestamp] Sending " . $input_file . " to s3...\n";
  close $logfh;

#--- creates an Amazon::S3 object ( the access key abd secret key are in the config file
#    and are just for this process
  my $s3 = Amazon::S3->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key,
          retry                 => 1
      }
  );#end new s3

#--- this sets up what bucket we're going to send to
#    NOTE: this should be a variable in config, not hard-coded
  my $bucket = $s3->bucket("escrowfiles");

#--- send the file to the bucket.  key is filename, value is file contents.
#    note the content_type may vary if we ever send anything other than
#    gpg encrypted files
  my $response = $bucket->add_key_filename(
    $filename,
    $input_file,
    {
      content_type => 'application/octet-stream',
    }
  );

#--- if the send to s3 succeeded, call the sub to move the encrypted file to the archive, otherwise, bubble up status
  if ( ! $response ) {
      open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Unable to send " . $filename . " to s3...: $s3->errstr\n";
      close $logfh;

      return 0;
  } else {
      open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Successfully sent " . $filename . " to s3...\n";
      close $logfh;

#--- call the clean up routine to move the encrypted file to archive
      $response = clean_up($input_file);
      return $response;
  }#end else


}#end send_to_s3

#--- this routine moves the encrypted file to archive...it does NOT delete the original file
sub clean_up {
  my $input_file = shift;
  open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  my $timestamp = localtime(time);
  print $logfh "[$timestamp] Cleaning up " . $input_file ."...\n";
  close $logfh;

  my($filename, $filedir, $fileext) = fileparse($input_file);
  my $encrypted_path = $encrypted_dir . "/" . $filename;
  my $archived_path = $archived_dir . "/" . $filename;


  open my $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
  $timestamp = localtime(time);
  print $logfh "[$timestamp] Archiving " . $encrypted_path . " to " . $archived_path . "\n";
  close $logfh;

#--- yeah, like the man said..move that file!
  my $result = move($encrypted_path, $archived_path);  

  if ( ! $result ) {
      open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Unable to archive " . $encrypted_path . " to ". $archived_path . "\n";
      close $logfh;

      return 0;
  } else {
      open $logfh, ">>", $log_file or die "Can't open the log file $log_file: $!";
      $timestamp = localtime(time);
      print $logfh "[$timestamp] Successfully archived " . $encrypted_path . "\n";
      close $logfh;

      return $result;
  }#end else
}# end clean_up
